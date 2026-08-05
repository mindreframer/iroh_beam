defmodule IrohBeam.ConnectionTest do
  use ExUnit.Case, async: false

  import IrohBeam.Eventually

  alias IrohBeam.{Connection, Endpoint, EndpointTicket, Error, Native}

  @alpn "iroh-beam/connection-test/1"

  setup do
    on_exit(fn ->
      assert_eventually(fn ->
        match?({:ok, %{active_connections: 0}}, Native.connection_snapshot())
      end)
    end)

    :ok
  end

  test "two direct endpoints mutually authenticate identity and ALPN" do
    {client_endpoint, server_endpoint, server_addr} = start_pair()
    {:ok, expected_client_id} = Endpoint.id(client_endpoint)
    {:ok, expected_server_id} = Endpoint.id(server_endpoint)

    accept = Task.async(fn -> Endpoint.accept(server_endpoint, timeout: 3_000) end)
    assert {:ok, outgoing} = Endpoint.connect(client_endpoint, server_addr, @alpn)
    assert {:ok, incoming} = Task.await(accept, 4_000)

    assert Connection.remote_id(outgoing) == expected_server_id
    assert Connection.remote_id(incoming) == expected_client_id
    assert Connection.alpn(outgoing) == @alpn
    assert Connection.alpn(incoming) == @alpn
    assert Connection.side(outgoing) == :client
    assert Connection.side(incoming) == :server
    assert Connection.role(outgoing) == :outgoing
    assert Connection.role(incoming) == :incoming
    assert is_integer(Connection.stable_id(outgoing))

    assert {:ok, %{kind: :direct, selected: true, rtt_microseconds: rtt}} =
             Connection.path(outgoing)

    assert is_integer(rtt) and rtt >= 0

    close_all([outgoing, incoming], [client_endpoint, server_endpoint])
  end

  test "address, ticket, and deterministic ID lookup dialing avoid public infrastructure" do
    {:ok, server} = start_endpoint()
    {:ok, server_addr} = Endpoint.addr(server)
    {:ok, server_id} = Endpoint.id(server)
    {:ok, ticket} = EndpointTicket.new(server_addr)

    {:ok, client} =
      Endpoint.start_link(
        alpns: [@alpn],
        network: :direct,
        bind: ["127.0.0.1:0"],
        address_book: [server_addr]
      )

    for target <- [server_addr, ticket, server_id] do
      accept = Task.async(fn -> Endpoint.accept(server, timeout: 3_000) end)
      assert {:ok, outgoing} = Endpoint.connect(client, target, @alpn)
      assert {:ok, incoming} = Task.await(accept, 4_000)
      Connection.close(outgoing)
      Connection.close(incoming)
    end

    close_all([], [client, server])
  end

  test "ID-only dialing without lookup or address data fails clearly" do
    {client, server, _server_addr} = start_pair()
    {:ok, server_id} = Endpoint.id(server)

    assert {:error,
            %Error{
              category: :resolution,
              operation: :connection_connect,
              message: "endpoint ID has no configured address information"
            }} = Endpoint.connect(client, server_id, @alpn)

    close_all([], [client, server])
  end

  test "unsupported ALPN, malformed target, and stopped endpoint are stable errors" do
    {client, server, server_addr} = start_pair()

    assert {:error, %Error{category: :invalid_argument, operation: :connection_connect}} =
             Endpoint.connect(client, :not_a_target, @alpn)

    accept = Task.async(fn -> Endpoint.accept(server, timeout: 3_000) end)

    assert {:error, %Error{category: :refused, operation: :connection_connect}} =
             Endpoint.connect(client, server_addr, "unsupported/alpn", timeout: 3_000)

    assert {:error, %Error{category: :refused, operation: :connection_accept}} =
             Task.await(accept, 4_000)

    assert :ok = Endpoint.close(client)

    assert {:error, %Error{category: :closed, operation: :endpoint}} =
             Endpoint.connect(client, server_addr, @alpn)

    assert :ok = Endpoint.close(server)
  end

  test "authenticated peers not on the allowlist never reach successful accept" do
    {:ok, client} = start_endpoint()
    {:ok, other} = start_endpoint()
    {:ok, allowed_id} = Endpoint.id(other)

    {:ok, server} =
      Endpoint.start_link(
        alpns: [@alpn],
        network: :direct,
        bind: ["127.0.0.1:0"],
        peer_allowlist: [allowed_id]
      )

    {:ok, server_addr} = Endpoint.addr(server)
    accept = Task.async(fn -> Endpoint.accept(server, timeout: 3_000) end)
    client_result = Endpoint.connect(client, server_addr, @alpn, timeout: 3_000)

    assert {:error, %Error{category: :unauthorized, operation: :connection_accept}} =
             Task.await(accept, 4_000)

    if match?({:ok, _connection}, client_result) do
      {:ok, connection} = client_result
      assert :ok = Connection.closed(connection, 3_000)
    end

    close_all([], [client, other, server])
  end

  test "pending accept is bounded, times out, and caller death cancels it" do
    {:ok, server} =
      Endpoint.start_link(
        alpns: [@alpn],
        network: :direct,
        bind: ["127.0.0.1:0"],
        limits: [max_pending_accepts: 1]
      )

    parent = self()

    caller =
      spawn(fn ->
        send(parent, :accept_started)
        send(parent, {:accept_result, Endpoint.accept(server, timeout: 60_000)})
      end)

    assert_receive :accept_started

    assert_eventually(fn ->
      {:ok, snapshot} = Native.endpoint_snapshot()
      snapshot.active_operations == 1
    end)

    assert {:error, %Error{category: :busy, operation: :connection_accept}} =
             Endpoint.accept(server, timeout: 100)

    Process.exit(caller, :kill)

    assert_eventually(fn ->
      {:ok, snapshot} = Native.endpoint_snapshot()
      snapshot.active_operations == 0
    end)

    refute_receive {:accept_result, _result}

    assert {:error, %Error{category: :timeout, operation: :connection_accept}} =
             Endpoint.accept(server, timeout: 10)

    assert_eventually(fn ->
      {:ok, snapshot} = Native.endpoint_snapshot()
      snapshot.active_operations == 0
    end)

    assert :ok = Endpoint.close(server)
  end

  test "connection limits reject growth beyond configured capacity" do
    {:ok, server} = start_endpoint()
    {:ok, server_addr} = Endpoint.addr(server)

    {:ok, client} =
      Endpoint.start_link(
        alpns: [@alpn],
        network: :direct,
        bind: ["127.0.0.1:0"],
        limits: [max_connections: 1]
      )

    first_accept = Task.async(fn -> Endpoint.accept(server, timeout: 3_000) end)
    {:ok, first_outgoing} = Endpoint.connect(client, server_addr, @alpn)
    {:ok, first_incoming} = Task.await(first_accept, 4_000)

    second_accept = Task.async(fn -> Endpoint.accept(server, timeout: 3_000) end)

    assert {:error, %Error{category: :capacity, operation: :connection_connect}} =
             Endpoint.connect(client, server_addr, @alpn)

    assert {:ok, second_incoming} = Task.await(second_accept, 4_000)
    Connection.close(second_incoming)
    close_all([first_outgoing, first_incoming], [client, server])
  end

  test "connection and endpoint close unblock waiters and release unrelated resources" do
    {client_endpoint, server_endpoint, server_addr} = start_pair()
    accept = Task.async(fn -> Endpoint.accept(server_endpoint, timeout: 3_000) end)
    {:ok, outgoing} = Endpoint.connect(client_endpoint, server_addr, @alpn)
    {:ok, incoming} = Task.await(accept, 4_000)

    waiter = Task.async(fn -> Connection.closed(outgoing, 5_000) end)
    assert :ok = Endpoint.close(server_endpoint)
    assert :ok = Task.await(waiter, 6_000)
    assert %Error{category: :closed} = Connection.close_reason(outgoing)
    assert Process.alive?(client_endpoint)

    Connection.close(incoming)
    Connection.close(outgoing)
    assert :ok = Endpoint.close(client_endpoint)
  end

  test "repeated connection lifecycle stays responsive and resources return to zero" do
    {client, server, server_addr} = start_pair()
    counter = :counters.new(1, [:atomics])
    parent = self()

    spinner =
      spawn(fn ->
        spin = fn spin ->
          receive do
            :stop -> send(parent, :stopped)
          after
            0 ->
              :counters.add(counter, 1, 1)
              spin.(spin)
          end
        end

        spin.(spin)
      end)

    for _index <- 1..10 do
      accept = Task.async(fn -> Endpoint.accept(server, timeout: 3_000) end)
      {:ok, outgoing} = Endpoint.connect(client, server_addr, @alpn)
      {:ok, incoming} = Task.await(accept, 4_000)
      Connection.close(outgoing)
      Connection.close(incoming)
    end

    send(spinner, :stop)
    assert_receive :stopped
    assert :counters.get(counter, 1) > 100
    close_all([], [client, server])
  end

  defp start_pair do
    {:ok, client} = start_endpoint()
    {:ok, server} = start_endpoint()
    {:ok, server_addr} = Endpoint.addr(server)
    {client, server, server_addr}
  end

  defp start_endpoint do
    Endpoint.start_link(alpns: [@alpn], network: :direct, bind: ["127.0.0.1:0"])
  end

  defp close_all(connections, endpoints) do
    Enum.each(connections, &Connection.close/1)

    Enum.each(endpoints, fn endpoint ->
      if Process.alive?(endpoint), do: Endpoint.close(endpoint)
    end)
  end
end
