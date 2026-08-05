defmodule IrohBeam.DistributionRelayIntegrationTest do
  use IrohBeam.FixtureCase, async: false

  alias IrohBeam.{DistributionProcess, EndpointAddr, Identity, Relay, SecretKey}

  @moduletag :relay
  @relay_url "http://127.0.0.1:3340"
  @token "iroh-beam-local-test-token-not-for-production"

  setup do
    assert relay_ready?()

    on_exit(fn ->
      _ =
        System.cmd("docker", ["compose", "up", "--detach", "iroh-relay"], stderr_to_stdout: true)
    end)

    :ok
  end

  test "three separate VMs form an explicit relay-only OTP topology", %{tmp_dir: tmp_dir} do
    unique = System.unique_integer([:positive])
    nodes = Enum.map(["a", "b", "c"], &String.to_atom("relay#{&1}#{unique}@host"))

    identities =
      Map.new(nodes, fn node ->
        path = Path.join(tmp_dir, "#{node}.key")
        {node, {path, endpoint_id(path)}}
      end)

    {:ok, relay} = Relay.new(@relay_url, token: @token)

    addresses =
      Map.new(identities, fn {node, {_path, id}} ->
        {:ok, addr} = EndpointAddr.new(id, relay_urls: [@relay_url])
        {node, addr}
      end)

    option_paths =
      Map.new(nodes, fn node ->
        {identity_path, _id} = Map.fetch!(identities, node)
        peers = addresses |> Map.delete(node)

        options = [
          name: node,
          name_domain: :shortnames,
          identity: {:file, identity_path},
          network: {:custom, [relay]},
          direct_ip: false,
          peers: peers,
          startup_timeout: 10_000,
          shutdown_timeout: 3_000,
          connect_timeout: 10_000,
          accept_timeout: 250,
          stream_timeout: 10_000,
          net_ticktime: 4,
          net_tickintensity: 4
        ]

        {node, write_options(tmp_dir, "#{node}.options", options)}
      end)

    [node_a, node_b, node_c] = nodes
    {:ok, a} = start_peer(option_paths[node_a], node_b)
    assert {:ok, a} = DistributionProcess.await_output(a, "PEER_READY #{node_a}", 20_000)
    {:ok, b} = start_peer(option_paths[node_b], node_c)
    assert {:ok, b} = DistributionProcess.await_output(b, "PEER_READY #{node_b}", 20_000)
    {:ok, c} = start_peer(option_paths[node_c], node_a)
    assert {:ok, c} = DistributionProcess.await_output(c, "PEER_READY #{node_c}", 20_000)

    assert {:ok, a} = DistributionProcess.send(a, "CONNECT\n")
    assert {:ok, a} = DistributionProcess.await_output(a, "CONNECT true", 20_000)
    assert {:ok, b} = DistributionProcess.send(b, "CONNECT\n")
    assert {:ok, b} = DistributionProcess.await_output(b, "CONNECT true", 20_000)
    assert {:ok, c} = DistributionProcess.send(c, "CONNECT\n")
    assert {:ok, c} = DistributionProcess.await_output(c, "CONNECT true", 20_000)

    for {process, expected} <- [
          {a, [node_b, node_c]},
          {b, [node_a, node_c]},
          {c, [node_a, node_b]}
        ] do
      assert {:ok, process} = DistributionProcess.send(process, "LIST\nINFO\nPING\nRPC\n")
      expected_list = "LIST #{inspect(Enum.sort(expected))}"
      assert {:ok, process} = DistributionProcess.await_output(process, expected_list, 10_000)
      assert {:ok, process} = DistributionProcess.await_output(process, "kind: :relay", 10_000)
      assert {:ok, process} = DistributionProcess.await_output(process, "PING :pong", 10_000)
      assert {:ok, _process} = DistributionProcess.await_output(process, "RPC ", 10_000)
    end

    assert {:ok, a} =
             DistributionProcess.send(a, "REGISTERED\nMONITOR\nLINK\nLARGE\nBURST\nIDLE\n")

    assert {:ok, a} = DistributionProcess.await_output(a, "REGISTERED \"registered-ok\"", 10_000)
    assert {:ok, a} = DistributionProcess.await_output(a, "MONITOR :killed", 10_000)
    assert {:ok, a} = DistributionProcess.await_output(a, "LINK :distribution_test_crash", 10_000)
    assert {:ok, a} = DistributionProcess.await_output(a, "LARGE true 2097152", 30_000)
    assert {:ok, a} = DistributionProcess.await_output(a, "BURST true", 20_000)
    assert {:ok, a} = DistributionProcess.await_output(a, "IDLE :pong", 10_000)

    {stop_output, 0} =
      System.cmd("docker", ["compose", "stop", "iroh-relay"], stderr_to_stdout: true)

    refute stop_output =~ "error"
    Process.sleep(6_000)
    a = %{a | output: ""}
    assert {:ok, a} = DistributionProcess.send(a, "LIST\n")
    assert {:ok, a} = DistributionProcess.await_output(a, "LIST []", 10_000)
    a = %{a | output: ""}
    assert {:ok, a} = DistributionProcess.send(a, "CONNECT\n")
    assert {:ok, a} = DistributionProcess.await_output(a, "CONNECT false", 15_000)

    stop_peer(a)
    stop_peer(b)
    stop_peer(c)

    {start_output, 0} =
      System.cmd("docker", ["compose", "up", "--detach", "iroh-relay"], stderr_to_stdout: true)

    refute start_output =~ "error"
    assert eventually(&relay_ready?/0, 150)

    {:ok, a2} = start_peer(option_paths[node_a], node_b)
    assert {:ok, a2} = DistributionProcess.await_output(a2, "PEER_READY #{node_a}", 20_000)
    {:ok, b2} = start_peer(option_paths[node_b], node_a)
    assert {:ok, b2} = DistributionProcess.await_output(b2, "PEER_READY #{node_b}", 20_000)
    assert {:ok, a2} = DistributionProcess.send(a2, "CONNECT\nINFO\nPING\n")
    assert {:ok, a2} = DistributionProcess.await_output(a2, "CONNECT true", 20_000)
    assert {:ok, a2} = DistributionProcess.await_output(a2, "kind: :relay", 10_000)
    assert {:ok, a2} = DistributionProcess.await_output(a2, "PING :pong", 10_000)
    stop_peer(a2)
    stop_peer(b2)
  end

  test "relay-authenticated peers still require matching OTP cookies", %{tmp_dir: tmp_dir} do
    unique = System.unique_integer([:positive])
    node_a = String.to_atom("cookiea#{unique}@host")
    node_b = String.to_atom("cookieb#{unique}@host")
    identity_a = Path.join(tmp_dir, "cookie-a.key")
    identity_b = Path.join(tmp_dir, "cookie-b.key")
    id_a = endpoint_id(identity_a)
    id_b = endpoint_id(identity_b)
    {:ok, relay} = Relay.new(@relay_url, token: @token)
    {:ok, addr_a} = EndpointAddr.new(id_a, relay_urls: [@relay_url])
    {:ok, addr_b} = EndpointAddr.new(id_b, relay_urls: [@relay_url])

    base = [
      network: {:custom, [relay]},
      direct_ip: false,
      startup_timeout: 10_000,
      accept_timeout: 250,
      stream_timeout: 10_000
    ]

    path_a =
      write_options(
        tmp_dir,
        "relay-cookie-a.options",
        Keyword.merge(base,
          name: node_a,
          identity: {:file, identity_a},
          peers: %{node_b => addr_b}
        )
      )

    path_b =
      write_options(
        tmp_dir,
        "relay-cookie-b.options",
        Keyword.merge(base,
          name: node_b,
          identity: {:file, identity_b},
          peers: %{node_a => addr_a}
        )
      )

    {:ok, a} = start_peer(path_a, node_b, "relay_cookie_a")
    assert {:ok, a} = DistributionProcess.await_output(a, "PEER_READY #{node_a}", 20_000)
    {:ok, b} = start_peer(path_b, node_a, "relay_cookie_b")
    assert {:ok, b} = DistributionProcess.await_output(b, "PEER_READY #{node_b}", 20_000)
    assert {:ok, b} = DistributionProcess.send(b, "CONNECT\n")
    assert {:ok, b} = DistributionProcess.await_output(b, "CONNECT false []", 15_000)
    refute DistributionProcess.output(a) =~ "relay_cookie_a"
    refute DistributionProcess.output(b) =~ "relay_cookie_b"
    stop_peer(a)
    stop_peer(b)
  end

  test "wrong private relay token fails before distribution readiness without disclosure", %{
    tmp_dir: tmp_dir
  } do
    node = String.to_atom("wrongrelay#{System.unique_integer([:positive])}@host")
    identity = Path.join(tmp_dir, "wrong.key")
    {:ok, relay} = Relay.new(@relay_url, token: "wrong-private-relay-token")

    options = [
      name: node,
      identity: {:file, identity},
      network: {:custom, [relay]},
      direct_ip: false,
      peers: %{},
      startup_timeout: 500
    ]

    path = write_options(tmp_dir, "wrong.options", options)
    {:ok, process} = start_peer(path, nil)

    assert {:ok, %{status: status, output: output}} =
             DistributionProcess.await_exit(process, 10_000)

    assert status != 0
    refute output =~ "wrong-private-relay-token"
    refute output =~ @token
  end

  defp endpoint_id(path) do
    {:ok, key} = Identity.load_or_create(path)
    {:ok, id} = SecretKey.endpoint_id(key)
    id
  end

  defp write_options(tmp_dir, name, options) do
    path = Path.join(tmp_dir, name)
    File.write!(path, :erlang.term_to_binary(options))
    path
  end

  defp start_peer(options_path, peer, cookie \\ "relay_distribution_cookie") do
    env = [
      {"MIX_ENV", "test"},
      {"IROH_BEAM_DISTRIBUTION_OPTIONS", options_path},
      {"IROH_BEAM_DISTRIBUTION_COOKIE", cookie}
    ]

    env = if peer, do: [{"IROH_BEAM_DISTRIBUTION_PEER", Atom.to_string(peer)} | env], else: env

    DistributionProcess.start(
      "elixir",
      [
        "--erl",
        "-proto_dist iroh -no_epmd",
        "-S",
        "mix",
        "run",
        "--no-compile",
        "test/support/distribution_peer.exs"
      ],
      env: env
    )
  end

  defp stop_peer(process) do
    {:ok, process} = DistributionProcess.send(process, "STOP\n")
    DistributionProcess.await_exit(process, 15_000)
  end

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(100)
      if attempts > 1, do: eventually(fun, attempts - 1), else: false
    end
  end

  defp relay_ready? do
    case :gen_tcp.connect(~c"127.0.0.1", 3340, [:binary, active: false], 1_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end
end
