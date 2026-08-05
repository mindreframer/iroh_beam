defmodule IrohBeam.EndpointTest do
  use IrohBeam.FixtureCase, async: false

  import ExUnit.CaptureLog
  import IrohBeam.Eventually

  alias IrohBeam.{Endpoint, Error, Native, Relay, SecretKey}

  @alpn "iroh-beam/endpoint-test/1"
  @token "synthetic-relay-token-never-log"

  setup do
    on_exit(fn ->
      assert_eventually(fn ->
        {:ok, snapshot} = Native.endpoint_snapshot()

        snapshot.active_endpoints == 0 and snapshot.active_identities == 0 and
          snapshot.active_operations == 0
      end)
    end)

    :ok
  end

  test "a direct endpoint binds under OTP and exposes lifecycle information" do
    {:ok, endpoint} = start_direct()

    assert {:ok, id} = Endpoint.id(endpoint)
    assert {:ok, [socket]} = Endpoint.bound_sockets(endpoint)
    assert String.starts_with?(socket, "127.0.0.1:")
    assert {:ok, addr} = Endpoint.addr(endpoint)
    assert addr.id == id
    assert addr.relay_urls == []
    assert addr.ip_addrs == [socket]
    assert Endpoint.online?(endpoint)
    assert :ok = Endpoint.await_online(endpoint)

    assert {:ok,
            %{
              status: :running,
              profile: :direct,
              relay_enabled?: false,
              address_lookup_enabled?: false,
              online?: true
            }} = Endpoint.status(endpoint)

    monitor = Process.monitor(endpoint)
    assert :ok = Endpoint.close(endpoint)
    assert_receive {:DOWN, ^monitor, :process, ^endpoint, :normal}
  end

  test "multiple endpoints coexist with isolated identities and shutdown state" do
    {:ok, first} = start_direct()
    {:ok, second} = start_direct()
    assert {:ok, first_id} = Endpoint.id(first)
    assert {:ok, second_id} = Endpoint.id(second)
    refute first_id == second_id

    assert :ok = Endpoint.close(first)
    assert Process.alive?(second)
    assert {:ok, %{status: :running}} = Endpoint.status(second)
    assert :ok = Endpoint.close(second)
  end

  test "persistent endpoint identity survives supervised restart", %{tmp_dir: tmp_dir} do
    identity_path = Path.join(tmp_dir, "supervised.identity")

    options = [
      identity: {:file, identity_path},
      alpns: [@alpn],
      network: :direct,
      bind: ["127.0.0.1:0"]
    ]

    {:ok, supervisor} = Supervisor.start_link([{Endpoint, options}], strategy: :one_for_one)
    [{_id, first, :worker, _modules}] = Supervisor.which_children(supervisor)
    assert {:ok, first_id} = Endpoint.id(first)

    Process.exit(first, :kill)

    assert_eventually(fn ->
      case Supervisor.which_children(supervisor) do
        [{_id, restarted, :worker, _modules}] -> is_pid(restarted) and restarted != first
        _other -> false
      end
    end)

    [{_id, restarted, :worker, _modules}] = Supervisor.which_children(supervisor)
    assert {:ok, ^first_id} = Endpoint.id(restarted)
    assert :ok = Endpoint.close(restarted)
    Supervisor.stop(supervisor)
  end

  test "duplicate live private identities are rejected and released on close" do
    {:ok, secret_key} = SecretKey.generate()

    options = [
      identity: secret_key,
      alpns: [@alpn],
      network: :direct,
      bind: ["127.0.0.1:0"]
    ]

    assert {:ok, endpoint} = Endpoint.start_link(options)

    assert {:error,
            %Error{
              category: :duplicate_identity,
              operation: :endpoint_bind,
              message: "endpoint identity is already active in this VM"
            }} = Endpoint.start_link(options)

    assert :ok = Endpoint.close(endpoint)

    assert_eventually(fn ->
      match?({:ok, %{active_identities: 0}}, Native.endpoint_snapshot())
    end)

    assert {:ok, replacement} = Endpoint.start_link(options)
    assert :ok = Endpoint.close(replacement)
  end

  test "owner death aborts the endpoint and frees its native state" do
    {:ok, endpoint} = start_direct()
    Process.unlink(endpoint)
    monitor = Process.monitor(endpoint)
    Process.exit(endpoint, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^endpoint, :killed}

    assert_eventually(fn ->
      match?(
        {:ok, %{active_endpoints: 0, active_identities: 0, active_operations: 0}},
        Native.endpoint_snapshot()
      )
    end)
  end

  test "failed bind and invalid options leave no endpoint resources" do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(socket)

    assert {:error, %Error{category: :bind_failed, operation: :endpoint_bind}} =
             Endpoint.start_link(
               alpns: [@alpn],
               network: :direct,
               bind: ["127.0.0.1:#{port}"]
             )

    :ok = :gen_udp.close(socket)

    assert {:error, %Error{category: :invalid_argument}} =
             Endpoint.start_link(alpns: [], network: :direct)

    assert {:error, %Error{category: :invalid_argument}} =
             Endpoint.start_link(alpns: [@alpn, @alpn], network: :direct)
  end

  test "minimal/direct mode is configured without external infrastructure" do
    {:ok, endpoint} = start_direct()
    Process.sleep(25)

    assert {:ok, status} = Endpoint.status(endpoint)
    refute status.relay_enabled?
    refute status.address_lookup_enabled?
    assert Enum.all?(status.bound_sockets, &String.starts_with?(&1, "127.0.0.1:"))
    assert {:ok, %{relay_urls: []}} = Endpoint.addr(endpoint)
    assert :ok = Endpoint.close(endpoint)
  end

  test "custom relays validate and redact authorization tokens" do
    assert {:ok, relay} = Relay.new("http://127.0.0.1:9", token: @token)
    assert inspect(relay) == "#IrohBeam.Relay<http://127.0.0.1:9/ token=redacted>"
    refute inspect(relay) =~ @token

    output =
      capture_log(fn ->
        assert {:ok, endpoint} =
                 Endpoint.start_link(
                   alpns: [@alpn],
                   network: {:custom, [relay]},
                   bind: ["127.0.0.1:0"]
                 )

        assert {:ok,
                %{
                  profile: :custom,
                  relay_enabled?: true,
                  address_lookup_enabled?: false
                }} = Endpoint.status(endpoint)

        refute inspect(Endpoint.status(endpoint)) =~ @token
        assert :ok = Endpoint.close(endpoint)
      end)

    refute output =~ @token

    assert {:error, %Error{category: :invalid_argument, operation: :relay}} =
             Relay.new("https://user:#{@token}@example.com")

    assert {:error, %Error{category: :invalid_argument, operation: :relay}} =
             Relay.new("https://example.com/?token=#{@token}")
  end

  test "startup and shutdown leave normal BEAM schedulers responsive" do
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

    for _index <- 1..5 do
      {:ok, endpoint} = start_direct()
      :ok = Endpoint.close(endpoint)
    end

    send(spinner, :stop)
    assert_receive :spinner_stopped
    assert :counters.get(counter, 1) > 100
  end

  defp start_direct do
    Endpoint.start_link(alpns: [@alpn], network: :direct, bind: ["127.0.0.1:0"])
  end
end
