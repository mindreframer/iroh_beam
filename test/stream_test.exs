defmodule IrohBeam.StreamTest do
  use ExUnit.Case, async: false

  import IrohBeam.Eventually

  alias IrohBeam.{Connection, Endpoint, Error, Native, Stream}

  @alpn "iroh-beam/stream-test/1"

  setup do
    on_exit(fn ->
      assert_eventually(fn ->
        {:ok, snapshot} = Native.stream_snapshot()
        snapshot.active_streams == 0 and snapshot.queued_bytes == 0
      end)
    end)

    :ok
  end

  test "bidirectional streams transfer exact bytes, IDs, finish, and EOF" do
    {client, server, endpoints} = connected_pair()
    {:ok, local} = Connection.open_bi(client)
    accept = Task.async(fn -> Connection.accept_bi(server, timeout: 3_000) end)

    assert :ok = Stream.send(local, "hello")
    assert :ok = Stream.finish(local)
    {:ok, remote} = Task.await(accept, 4_000)

    assert Stream.id(local) == Stream.id(remote)
    assert {:ok, "hello"} = Stream.recv(remote, 64)
    assert :eof = Stream.recv(remote, 64)
    assert {:ok, %{direction: :bi, send: true, recv: true}} = Stream.info(remote)

    cleanup([local, remote], [client, server], endpoints)
  end

  test "unidirectional notification streams expose only their valid halves" do
    {client, server, endpoints} = connected_pair()
    {:ok, sender} = Connection.open_uni(client)
    accept = Task.async(fn -> Connection.accept_uni(server, timeout: 3_000) end)
    assert :ok = Stream.send(sender, "notification")
    assert :ok = Stream.finish(sender)
    {:ok, receiver} = Task.await(accept, 4_000)

    assert sender.send? and not sender.recv?
    assert receiver.recv? and not receiver.send?
    assert {:ok, "notification"} = Stream.recv(receiver, 1_024)
    assert :eof = Stream.recv(receiver, 1_024)
    assert {:error, %Error{category: :invalid_argument}} = Stream.recv(sender, 10)
    assert {:error, %Error{category: :invalid_argument}} = Stream.send(receiver, "no")

    cleanup([sender, receiver], [client, server], endpoints)
  end

  test "one reusable connection handles request-response and full-duplex progress" do
    {client, server, endpoints} = connected_pair()

    for request <- ["one", "two", "three"] do
      {:ok, local} = Connection.open_bi(client)
      accept = Task.async(fn -> Connection.accept_bi(server, timeout: 3_000) end)
      sender = Task.async(fn -> Stream.send(local, request) end)
      {:ok, remote} = Task.await(accept, 4_000)
      assert :ok = Task.await(sender)
      assert {:ok, ^request} = Stream.recv(remote, 64)

      response = String.upcase(request)
      server_send = Task.async(fn -> Stream.send(remote, response) end)
      client_recv = Task.async(fn -> Stream.recv(local, 64) end)
      assert :ok = Task.await(server_send)
      assert {:ok, ^response} = Task.await(client_recv)

      Stream.finish(local)
      Stream.finish(remote)
      Stream.abort(local)
      Stream.abort(remote)
    end

    cleanup([], [client, server], endpoints)
  end

  test "same receive half is busy while the opposite send half remains usable" do
    {client, server, endpoints} = connected_pair()
    {:ok, local} = Connection.open_bi(client)
    accept = Task.async(fn -> Connection.accept_bi(server, timeout: 3_000) end)
    Stream.send(local, "open")
    {:ok, remote} = Task.await(accept, 4_000)
    assert {:ok, "open"} = Stream.recv(remote, 64)

    pending = Task.async(fn -> Stream.recv(remote, 64, timeout: 5_000) end)
    assert_eventually(fn -> Native.operation_snapshot() > 0 end)

    assert {:error, %Error{category: :busy, operation: :stream_recv}} =
             Stream.recv(remote, 64, timeout: 100)

    assert :ok = Stream.send(remote, "opposite-half")
    assert {:ok, "opposite-half"} = Stream.recv(local, 64)
    assert :ok = Stream.send(local, "winning-read-remains-usable")
    assert {:ok, "winning-read-remains-usable"} = Task.await(pending, 6_000)

    stopped = Task.async(fn -> Stream.recv(remote, 64, timeout: 5_000) end)
    assert_eventually(fn -> Native.operation_snapshot() > 0 end)
    assert :ok = Stream.stop(remote, 7)
    assert {:error, %Error{category: :peer_aborted}} = Task.await(stopped, 6_000)

    cleanup([local, remote], [client, server], endpoints)
  end

  test "reset and stop propagate stable peer-abort results" do
    {client, server, endpoints} = connected_pair()

    {:ok, local} = Connection.open_bi(client)
    accept = Task.async(fn -> Connection.accept_bi(server, timeout: 3_000) end)
    Stream.send(local, "before-reset")
    {:ok, remote} = Task.await(accept, 4_000)
    assert {:ok, "before-reset"} = Stream.recv(remote, 64)
    assert :ok = Stream.reset(local, 42)
    assert {:error, %Error{category: :peer_aborted}} = Stream.recv(remote, 64)

    {:ok, local2} = Connection.open_bi(client)
    accept2 = Task.async(fn -> Connection.accept_bi(server, timeout: 3_000) end)
    Stream.send(local2, "before-stop")
    {:ok, remote2} = Task.await(accept2, 4_000)
    assert {:ok, "before-stop"} = Stream.recv(remote2, 64)
    assert :ok = Stream.stop(remote2, 9)

    assert_eventually(
      fn ->
        match?(
          {:error, %Error{category: :peer_aborted}},
          Stream.send(local2, "after-stop")
        )
      end,
      3_000
    )

    cleanup([local, remote, local2, remote2], [client, server], endpoints)
  end

  test "large transfer is chunked, bounded, exact, and scheduler responsive" do
    {client, server, endpoints} = connected_pair()
    payload = :binary.copy(<<0, 1, 2, 3, 4, 5, 6, 7>>, 256 * 1_024)
    {:ok, local} = Connection.open_uni(client)
    accept = Task.async(fn -> Connection.accept_uni(server, timeout: 3_000) end)

    counter = :counters.new(1, [:atomics])
    parent = self()

    spinner =
      spawn(fn ->
        spin = fn spin ->
          receive do
            :stop -> send(parent, :spinner_stopped)
          after
            0 ->
              :counters.add(counter, 1, 1)
              spin.(spin)
          end
        end

        spin.(spin)
      end)

    sender =
      Task.async(fn ->
        :ok = Stream.send(local, payload, chunk_size: 32 * 1_024, timeout: 10_000)
        Stream.finish(local)
      end)

    {:ok, remote} = Task.await(accept, 4_000)
    assert {:ok, ^payload} = Stream.recv_to_end(remote, byte_size(payload), timeout: 10_000)
    assert :ok = Task.await(sender, 11_000)
    send(spinner, :stop)
    assert_receive :spinner_stopped
    assert :counters.get(counter, 1) > 100

    assert {:ok, snapshot} = Native.stream_snapshot()
    assert snapshot.queued_bytes == 0
    assert snapshot.peak_queued_bytes <= byte_size(payload)

    cleanup([local, remote], [client, server], endpoints)
  end

  test "receive and send limits reject unsafe allocations before I/O" do
    {client, server, endpoints} = connected_pair()
    {:ok, stream} = Connection.open_bi(client)

    for invalid <- [0, -1, 16 * 1_024 * 1_024 + 1] do
      assert {:error, %Error{category: :invalid_argument, operation: :stream_recv}} =
               Stream.recv(stream, invalid)
    end

    assert {:error, %Error{category: :invalid_argument, operation: :stream_send}} =
             Stream.send(stream, "too much", max_bytes: 3)

    assert {:error, %Error{category: :invalid_argument, operation: :stream_recv}} =
             Stream.recv_to_end(stream, 0)

    cleanup([stream], [client, server], endpoints)
  end

  test "datagrams round-trip and enforce current maximum and receive cancellation" do
    {client, server, endpoints} = connected_pair()

    assert {:ok, %{max_size: max_size, send_buffer_space: capacity}} =
             Connection.datagram_info(client)

    assert is_integer(max_size) and max_size > 0
    assert is_integer(capacity) and capacity >= 0
    assert :ok = Connection.send_datagram(client, "unreliable")
    assert {:ok, "unreliable"} = Connection.recv_datagram(server)

    assert {:error, %Error{category: :too_large, operation: :datagram_send}} =
             Connection.send_datagram(client, :binary.copy(<<0>>, max(max_size + 1, 64 * 1_024)))

    pending = Task.async(fn -> Connection.recv_datagram(server, timeout: 5_000) end)
    assert_eventually(fn -> Native.operation_snapshot() > 0 end)

    assert {:error, %Error{category: :busy, operation: :datagram_recv}} =
             Connection.recv_datagram(server, timeout: 100)

    Task.shutdown(pending, :brutal_kill)
    assert_eventually(fn -> Native.operation_snapshot() == 0 end)

    cleanup([], [client, server], endpoints)
  end

  test "connection abort unblocks a waiting stream receive" do
    {client, server, endpoints} = connected_pair()
    {:ok, local} = Connection.open_bi(client)
    accept = Task.async(fn -> Connection.accept_bi(server, timeout: 3_000) end)
    Stream.send(local, "open")
    {:ok, remote} = Task.await(accept, 4_000)
    assert {:ok, "open"} = Stream.recv(remote, 64)

    reader = Task.async(fn -> Stream.recv(remote, 64, timeout: 5_000) end)
    assert_eventually(fn -> Native.operation_snapshot() > 0 end)
    Connection.close(client)
    assert {:error, %Error{category: :peer_aborted}} = Task.await(reader, 6_000)

    cleanup([local, remote], [server], endpoints)
  end

  defp connected_pair do
    {:ok, client_endpoint} = start_endpoint()
    {:ok, server_endpoint} = start_endpoint()
    {:ok, server_addr} = Endpoint.addr(server_endpoint)
    accept = Task.async(fn -> Endpoint.accept(server_endpoint, timeout: 3_000) end)
    {:ok, client} = Endpoint.connect(client_endpoint, server_addr, @alpn)
    {:ok, server} = Task.await(accept, 4_000)
    {client, server, [client_endpoint, server_endpoint]}
  end

  defp start_endpoint do
    Endpoint.start_link(alpns: [@alpn], network: :direct, bind: ["127.0.0.1:0"])
  end

  defp cleanup(streams, connections, endpoints) do
    Enum.each(streams, fn stream ->
      case Stream.abort(stream) do
        :ok -> :ok
        {:error, _error} -> :ok
      end
    end)

    Enum.each(connections, &Connection.close/1)

    Enum.each(endpoints, fn endpoint ->
      if Process.alive?(endpoint), do: Endpoint.close(endpoint)
    end)
  end
end
