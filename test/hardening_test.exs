defmodule IrohBeam.HardeningTest do
  use ExUnit.Case, async: false

  import IrohBeam.Eventually

  alias IrohBeam.{Connection, Endpoint, Native, Stream}

  @alpn "iroh-beam/hardening-test/1"

  test "repeated endpoint, connection, stream, operation, and byte resources plateau" do
    before = snapshots()

    for _iteration <- 1..20 do
      {:ok, client_endpoint} = start_endpoint()
      {:ok, server_endpoint} = start_endpoint()
      {:ok, server_addr} = Endpoint.addr(server_endpoint)
      accept = Task.async(fn -> Endpoint.accept(server_endpoint, timeout: 3_000) end)
      {:ok, client} = Endpoint.connect(client_endpoint, server_addr, @alpn)
      {:ok, server} = Task.await(accept, 4_000)

      {:ok, sender} = Connection.open_uni(client)
      stream_accept = Task.async(fn -> Connection.accept_uni(server, timeout: 3_000) end)
      :ok = Stream.send(sender, "plateau")
      :ok = Stream.finish(sender)
      {:ok, receiver} = Task.await(stream_accept, 4_000)
      {:ok, "plateau"} = Stream.recv(receiver, 64)
      :eof = Stream.recv(receiver, 64)

      Stream.abort(sender)
      Stream.abort(receiver)
      Connection.close(client)
      Connection.close(server)
      Endpoint.close(client_endpoint)
      Endpoint.close(server_endpoint)
    end

    assert_eventually(fn -> snapshots() == before end, 5_000)
  end

  test "bounded oversized transfer returns queued bytes and BEAM binary memory near baseline" do
    # Measure after a full GC, transfer 4 MiB in 32 KiB chunks, close every owner,
    # GC again, then allow 8 MiB for allocator/cache noise retained by the VM.
    :erlang.garbage_collect()
    before_binary = :erlang.memory(:binary)
    {:ok, client_endpoint} = start_endpoint()
    {:ok, server_endpoint} = start_endpoint()
    {:ok, server_addr} = Endpoint.addr(server_endpoint)
    accept = Task.async(fn -> Endpoint.accept(server_endpoint, timeout: 3_000) end)
    {:ok, client} = Endpoint.connect(client_endpoint, server_addr, @alpn)
    {:ok, server} = Task.await(accept, 4_000)
    payload = :binary.copy(<<0x5A>>, 4 * 1_024 * 1_024)

    {:ok, sender} = Connection.open_uni(client)
    stream_accept = Task.async(fn -> Connection.accept_uni(server, timeout: 3_000) end)

    send_task =
      Task.async(fn ->
        :ok = Stream.send(sender, payload, chunk_size: 32 * 1_024, timeout: 10_000)
        Stream.finish(sender)
      end)

    {:ok, receiver} = Task.await(stream_accept, 4_000)

    recv_task =
      Task.async(fn -> Stream.recv_to_end(receiver, byte_size(payload), timeout: 10_000) end)

    assert :ok = Task.await(send_task, 11_000)
    assert {:ok, ^payload} = Task.await(recv_task, 11_000)

    Stream.abort(sender)
    Stream.abort(receiver)
    Connection.close(client)
    Connection.close(server)
    Endpoint.close(client_endpoint)
    Endpoint.close(server_endpoint)
    payload = nil
    assert payload == nil
    :erlang.garbage_collect()

    assert_eventually(fn ->
      {:ok, stream_snapshot} = Native.stream_snapshot()
      stream_snapshot.queued_bytes == 0 and stream_snapshot.active_streams == 0
    end)

    after_binary = :erlang.memory(:binary)
    assert after_binary <= before_binary + 8 * 1_024 * 1_024
  end

  defp snapshots do
    {:ok, endpoint} = Native.endpoint_snapshot()
    {:ok, connection} = Native.connection_snapshot()
    {:ok, stream} = Native.stream_snapshot()

    %{
      endpoints: endpoint.active_endpoints,
      identities: endpoint.active_identities,
      operations: endpoint.active_operations,
      connections: connection.active_connections,
      streams: stream.active_streams,
      queued_bytes: stream.queued_bytes
    }
  end

  defp start_endpoint do
    Endpoint.start_link(alpns: [@alpn], network: :direct, bind: ["127.0.0.1:0"])
  end
end
