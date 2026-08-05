defmodule IrohBeam.DistributionHandshakeTest do
  use IrohBeam.FixtureCase, async: false

  alias IrohBeam.{DistributionProcess, EndpointAddr, Identity, SecretKey}

  test "separate VMs complete the standard OTP handshake over direct Iroh", %{tmp_dir: tmp_dir} do
    unique = System.unique_integer([:positive])
    node_a = String.to_atom("a#{unique}@host")
    node_b = String.to_atom("b#{unique}@host")
    identity_a = Path.join(tmp_dir, "a.key")
    identity_b = Path.join(tmp_dir, "b.key")
    id_a = endpoint_id(identity_a)
    id_b = endpoint_id(identity_b)
    port_a = free_udp_port()
    port_b = free_udp_port()
    {:ok, addr_a} = EndpointAddr.new(id_a, ip_addrs: ["127.0.0.1:#{port_a}"])
    {:ok, addr_b} = EndpointAddr.new(id_b, ip_addrs: ["127.0.0.1:#{port_b}"])

    options_a =
      options(node_a, identity_a, port_a, %{node_b => addr_b})

    options_b =
      options(node_b, identity_b, port_b, %{node_a => addr_a})

    path_a = write_options(tmp_dir, "a.options", options_a)
    path_b = write_options(tmp_dir, "b.options", options_b)

    {:ok, a} = start_peer(path_a)
    assert {:ok, a} = DistributionProcess.await_output(a, "PEER_READY #{node_a}", 15_000)
    {:ok, b} = start_peer(path_b)
    assert {:ok, b} = DistributionProcess.await_output(b, "PEER_READY #{node_b}", 15_000)

    assert {:ok, b} = DistributionProcess.send(b, "CONNECT\n")
    assert {:ok, b} = DistributionProcess.await_output(b, "CONNECT true", 15_000)
    assert DistributionProcess.output(b) =~ inspect(node_a)

    assert {:ok, a} = DistributionProcess.send(a, "LIST\n")
    assert {:ok, a} = DistributionProcess.await_output(a, "LIST [#{inspect(node_b)}]", 5_000)
    assert {:ok, a} = DistributionProcess.send(a, "INFO\n")
    assert {:ok, a} = DistributionProcess.await_output(a, "kind: :direct", 5_000)
    assert {:ok, b} = DistributionProcess.send(b, "INFO\n")
    assert {:ok, b} = DistributionProcess.await_output(b, "kind: :direct", 5_000)

    assert {:ok, b} = DistributionProcess.send(b, "STOP\n")
    assert {:ok, %{status: 0}} = DistributionProcess.await_exit(b, 10_000)
    assert {:ok, a} = DistributionProcess.send(a, "STOP\n")
    assert {:ok, %{status: 0}} = DistributionProcess.await_exit(a, 10_000)
  end

  test "simultaneous reciprocal setup converges to one node entry", %{tmp_dir: tmp_dir} do
    unique = System.unique_integer([:positive])
    node_a = String.to_atom("racea#{unique}@host")
    node_b = String.to_atom("raceb#{unique}@host")
    identity_a = Path.join(tmp_dir, "race-a.key")
    identity_b = Path.join(tmp_dir, "race-b.key")
    id_a = endpoint_id(identity_a)
    id_b = endpoint_id(identity_b)
    port_a = free_udp_port()
    port_b = free_udp_port()
    {:ok, addr_a} = EndpointAddr.new(id_a, ip_addrs: ["127.0.0.1:#{port_a}"])
    {:ok, addr_b} = EndpointAddr.new(id_b, ip_addrs: ["127.0.0.1:#{port_b}"])

    path_a =
      write_options(
        tmp_dir,
        "race-a.options",
        options(node_a, identity_a, port_a, %{node_b => addr_b})
      )

    path_b =
      write_options(
        tmp_dir,
        "race-b.options",
        options(node_b, identity_b, port_b, %{node_a => addr_a})
      )

    {:ok, a} = start_peer(path_a)
    assert {:ok, a} = DistributionProcess.await_output(a, "PEER_READY #{node_a}", 15_000)
    {:ok, b} = start_peer(path_b)
    assert {:ok, b} = DistributionProcess.await_output(b, "PEER_READY #{node_b}", 15_000)

    assert {:ok, a} = DistributionProcess.send(a, "CONNECT\n")
    assert {:ok, b} = DistributionProcess.send(b, "CONNECT\n")
    assert {:ok, a} = DistributionProcess.await_output(a, "CONNECT ", 15_000)
    assert {:ok, b} = DistributionProcess.await_output(b, "CONNECT ", 15_000)
    assert DistributionProcess.output(a) =~ inspect(node_b)
    assert DistributionProcess.output(b) =~ inspect(node_a)

    assert {:ok, a} = DistributionProcess.send(a, "LIST\n")
    assert {:ok, a} = DistributionProcess.await_output(a, "LIST [#{inspect(node_b)}]", 5_000)
    assert {:ok, b} = DistributionProcess.send(b, "LIST\n")
    assert {:ok, b} = DistributionProcess.await_output(b, "LIST [#{inspect(node_a)}]", 5_000)
    stop_peer(a)
    stop_peer(b)
  end

  test "wrong cookies and configured identity/name mismatches never emit node-up", %{
    tmp_dir: tmp_dir
  } do
    unique = System.unique_integer([:positive])
    node_a = String.to_atom("securea#{unique}@host")
    node_b = String.to_atom("secureb#{unique}@host")
    fake_b = String.to_atom("claimed#{unique}@host")
    identity_a = Path.join(tmp_dir, "secure-a.key")
    identity_b = Path.join(tmp_dir, "secure-b.key")
    identity_c = Path.join(tmp_dir, "secure-c.key")
    id_a = endpoint_id(identity_a)
    id_b = endpoint_id(identity_b)
    id_c = endpoint_id(identity_c)
    port_a = free_udp_port()
    port_b = free_udp_port()
    {:ok, addr_a} = EndpointAddr.new(id_a, ip_addrs: ["127.0.0.1:#{port_a}"])
    {:ok, addr_b} = EndpointAddr.new(id_b, ip_addrs: ["127.0.0.1:#{port_b}"])

    wrong_cookie_a =
      write_options(
        tmp_dir,
        "cookie-a.options",
        options(node_a, identity_a, port_a, %{node_b => addr_b})
      )

    wrong_cookie_b =
      write_options(
        tmp_dir,
        "cookie-b.options",
        options(node_b, identity_b, port_b, %{node_a => addr_a})
      )

    {:ok, a} = start_peer(wrong_cookie_a, "cookie_a")
    assert {:ok, a} = DistributionProcess.await_output(a, "PEER_READY #{node_a}", 15_000)
    {:ok, b} = start_peer(wrong_cookie_b, "cookie_b")
    assert {:ok, b} = DistributionProcess.await_output(b, "PEER_READY #{node_b}", 15_000)
    assert {:ok, b} = DistributionProcess.send(b, "CONNECT\n")
    assert {:ok, b} = DistributionProcess.await_output(b, "CONNECT false []", 10_000)
    stop_peer(a)
    stop_peer(b)

    port_a2 = free_udp_port()
    port_b2 = free_udp_port()
    {:ok, addr_a2} = EndpointAddr.new(id_a, ip_addrs: ["127.0.0.1:#{port_a2}"])
    {:ok, addr_b2} = EndpointAddr.new(id_b, ip_addrs: ["127.0.0.1:#{port_b2}"])
    {:ok, addr_c} = EndpointAddr.new(id_c, ip_addrs: ["127.0.0.1:#{free_udp_port()}"])

    mismatch_a =
      write_options(
        tmp_dir,
        "mismatch-a.options",
        options(node_a, identity_a, port_a2, %{fake_b => addr_b2, node_b => addr_c})
      )

    mismatch_b =
      write_options(
        tmp_dir,
        "mismatch-b.options",
        options(node_b, identity_b, port_b2, %{node_a => addr_a2})
      )

    {:ok, a2} = start_peer(mismatch_a)
    assert {:ok, a2} = DistributionProcess.await_output(a2, "PEER_READY #{node_a}", 15_000)
    {:ok, b2} = start_peer(mismatch_b)
    assert {:ok, b2} = DistributionProcess.await_output(b2, "PEER_READY #{node_b}", 15_000)
    assert {:ok, b2} = DistributionProcess.send(b2, "CONNECT\n")
    assert {:ok, b2} = DistributionProcess.await_output(b2, "CONNECT false []", 10_000)
    stop_peer(a2)
    stop_peer(b2)
  end

  defp options(name, identity, port, peers) do
    [
      name: name,
      name_domain: :shortnames,
      identity: {:file, identity},
      network: :direct,
      bind: ["127.0.0.1:#{port}"],
      peers: peers,
      startup_timeout: 5_000,
      shutdown_timeout: 2_000,
      connect_timeout: 5_000,
      accept_timeout: 100,
      stream_timeout: 5_000
    ]
  end

  defp endpoint_id(path) do
    {:ok, key} = Identity.load_or_create(path)
    {:ok, id} = SecretKey.endpoint_id(key)
    id
  end

  defp free_udp_port do
    {:ok, socket} = :gen_udp.open(0, ip: {127, 0, 0, 1})
    {:ok, {_ip, port}} = :inet.sockname(socket)
    :ok = :gen_udp.close(socket)
    port
  end

  defp write_options(tmp_dir, name, options) do
    path = Path.join(tmp_dir, name)
    File.write!(path, :erlang.term_to_binary(options))
    path
  end

  defp start_peer(options_path, cookie \\ "shared_cookie") do
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
      env: [
        {"MIX_ENV", "test"},
        {"IROH_BEAM_DISTRIBUTION_OPTIONS", options_path},
        {"IROH_BEAM_DISTRIBUTION_COOKIE", cookie}
      ]
    )
  end

  defp stop_peer(process) do
    {:ok, process} = DistributionProcess.send(process, "STOP\n")
    DistributionProcess.await_exit(process, 10_000)
  end
end
