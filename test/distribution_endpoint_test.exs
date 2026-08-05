defmodule IrohBeam.DistributionEndpointTest do
  use IrohBeam.FixtureCase, async: false

  alias IrohBeam.{Connection, Distribution.Config, Endpoint, Identity, Native, Stream}

  @alpn "iroh-beam/erlang-distribution/1"

  setup %{tmp_dir: tmp_dir} do
    Config.uninstall()

    on_exit(fn ->
      if Process.whereis(:iroh_dist_endpoint), do: :iroh_dist_endpoint.stop()
      Config.uninstall()
    end)

    {:ok, peer_key} = Identity.generate()

    {:ok, peer} =
      Endpoint.start_link(
        identity: peer_key,
        alpns: [@alpn],
        network: :direct,
        startup_timeout: 5_000
      )

    :ok = Endpoint.await_online(peer, 5_000)
    {:ok, peer_addr} = Endpoint.addr(peer)

    {:ok, config} =
      Config.validate(
        name: :local@host,
        identity: {:file, Path.join(tmp_dir, "distribution.key")},
        network: :direct,
        peers: %{:peer@host => peer_addr},
        accept_timeout: 100,
        stream_timeout: 2_000
      )

    :ok = Config.install(config)
    {:ok, worker} = :iroh_dist_endpoint.start_link()

    on_exit(fn ->
      if Process.alive?(peer), do: Endpoint.close(peer)
    end)

    {:ok, worker: worker, peer: peer, peer_addr: peer_addr}
  end

  test "dedicated endpoint reports bounded status and coexists with a general endpoint",
       context do
    assert {:ok, status} = :iroh_dist_endpoint.status()
    assert status.ready
    assert status.name == :local@host
    assert status.network == :direct
    assert status.configured_peers == 1
    assert status.active_links == 0
    assert status.endpoint_id != context.peer_addr.id

    assert {:ok, listener} = :iroh_dist_endpoint.listener()
    assert listener.pid == context.worker
    assert listener.endpoint_id == status.endpoint_id
    assert listener.creation >= 4

    assert {:ok, info} = :iroh_dist_endpoint.peer_info(:peer@host)
    assert info.expected_id == context.peer_addr.id
    assert info.state == :configured
    assert {:error, :unknown_peer} = :iroh_dist_endpoint.peer_info(:other@host)
  end

  test "outgoing internal primitive opens one authenticated bidirectional stream", %{peer: peer} do
    acceptor =
      Task.async(fn ->
        with {:ok, connection} <- Endpoint.accept(peer, timeout: 2_000),
             {:ok, stream} <- Connection.accept_bi(connection, timeout: 2_000),
             {:ok, "hello"} <- Stream.recv(stream, 5, timeout: 2_000),
             :ok <- Stream.send(stream, "ok", timeout: 2_000) do
          {connection, stream}
        end
      end)

    assert {:ok, session} = :iroh_dist_endpoint.connect(:peer@host)
    assert {:ok, info} = Stream.info(session.stream)
    assert info.direction == :bi
    assert :ok = Stream.send(session.stream, "hello", timeout: 2_000)
    assert {:ok, "ok"} = Stream.recv(session.stream, 2, timeout: 2_000)

    {peer_connection, peer_stream} = Task.await(acceptor, 3_000)
    :ok = Stream.abort(peer_stream)
    :ok = Connection.close(peer_connection)
    :ok = :iroh_dist_endpoint.close_session(session)
  end

  test "incoming configured identity is admitted before stream handoff", %{peer: peer} do
    {:ok, listener} = :iroh_dist_endpoint.listener()

    dialer =
      Task.async(fn ->
        with {:ok, connection} <-
               Endpoint.connect(peer, listener.endpoint_addr, @alpn, timeout: 2_000),
             {:ok, stream} <- Connection.open_bi(connection, timeout: 2_000),
             :ok <- Stream.send(stream, "in", timeout: 2_000) do
          {connection, stream}
        end
      end)

    assert {:ok, session} = :iroh_dist_endpoint.take_incoming(3_000)
    assert session.remote_id == context_peer_id(peer)
    assert {:ok, "in"} = Stream.recv(session.stream, 2, timeout: 2_000)

    {connection, stream} = Task.await(dialer, 3_000)
    :ok = Stream.abort(stream)
    :ok = Connection.close(connection)
    :ok = :iroh_dist_endpoint.close_session(session)
  end

  test "unknown identities and wrong ALPN never reach incoming handoff", %{tmp_dir: tmp_dir} do
    {:ok, listener} = :iroh_dist_endpoint.listener()

    {:ok, unknown} =
      Endpoint.start_link(
        identity: {:file, Path.join(tmp_dir, "unknown.key")},
        alpns: [@alpn, "wrong/1"],
        network: :direct
      )

    :ok = Endpoint.await_online(unknown, 5_000)

    case Endpoint.connect(unknown, listener.endpoint_addr, @alpn, timeout: 2_000) do
      {:ok, connection} ->
        _ = Connection.closed(connection, 2_000)
        :ok = Connection.close(connection)

      {:error, error} ->
        assert error.category in [:closed, :refused]
    end

    assert {:error, wrong_alpn_error} =
             Endpoint.connect(unknown, listener.endpoint_addr, "wrong/1", timeout: 2_000)

    assert wrong_alpn_error.category in [:closed, :refused]
    Process.sleep(100)
    assert {:ok, %{pending_incoming: 0}} = :iroh_dist_endpoint.status()
    :ok = Endpoint.close(unknown)
  end

  test "worker stop closes endpoint, accept, and operation resources" do
    {:ok, before_stop} = Native.endpoint_snapshot()
    assert before_stop.active_endpoints >= 2

    assert :ok = :iroh_dist_endpoint.stop()
    assert {:error, :not_started} = :iroh_dist_endpoint.status()

    assert eventually(fn ->
             {:ok, snapshot} = Native.endpoint_snapshot()

             snapshot.active_endpoints == before_stop.active_endpoints - 1 and
               snapshot.active_operations == 0
           end)
  end

  defp context_peer_id(peer) do
    {:ok, id} = Endpoint.id(peer)
    id
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
