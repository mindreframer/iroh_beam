defmodule IrohBeam.PrecompiledDistributionSmoke do
  alias IrohBeam.{EndpointAddr, Identity, SecretKey}

  def run do
    root = Path.join(System.tmp_dir!(), "iroh-beam-precompiled-dist-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    try do
      [port_a, port_b] = free_udp_ports(2)
      node_a = :precompiled_a@host
      node_b = :precompiled_b@host
      identity_a = Path.join(root, "a.key")
      identity_b = Path.join(root, "b.key")
      id_a = endpoint_id(identity_a)
      id_b = endpoint_id(identity_b)
      {:ok, addr_a} = EndpointAddr.new(id_a, ip_addrs: ["127.0.0.1:#{port_a}"])
      {:ok, addr_b} = EndpointAddr.new(id_b, ip_addrs: ["127.0.0.1:#{port_b}"])

      path_a = write_options(root, "a.options", options(node_a, identity_a, port_a, %{node_b => addr_b}))
      path_b = write_options(root, "b.options", options(node_b, identity_b, port_b, %{node_a => addr_a}))
      {:ok, a} = start_peer(path_a)
      {:ok, a} = await(a, "READY #{node_a}", 20_000)
      {:ok, b} = start_peer(path_b)
      {:ok, b} = await(b, "READY #{node_b}", 20_000)
      {:ok, b} = send_data(b, "CONNECT\nPING\n")
      {:ok, b} = await(b, "CONNECT true", 20_000)
      {:ok, b} = await(b, "PING {:pong, #{inspect(node_a)}}", 10_000)
      stop(b)
      stop(a)
      IO.puts("Precompiled no-Rust OTP distribution smoke passed")
    after
      File.rm_rf!(root)
    end
  end

  defp options(name, identity, port, peers) do
    [
      name: name,
      identity: {:file, identity},
      network: :direct,
      bind: ["127.0.0.1:#{port}"],
      peers: peers,
      accept_timeout: 100,
      stream_timeout: 10_000
    ]
  end

  defp endpoint_id(path) do
    {:ok, key} = Identity.load_or_create(path)
    {:ok, id} = SecretKey.endpoint_id(key)
    id
  end

  defp free_udp_ports(count) do
    sockets =
      for _ <- 1..count do
        {:ok, socket} = :gen_udp.open(0, ip: {127, 0, 0, 1})
        socket
      end

    ports =
      Enum.map(sockets, fn socket ->
        {:ok, {_ip, port}} = :inet.sockname(socket)
        port
      end)

    Enum.each(sockets, &:gen_udp.close/1)
    ports
  end

  defp write_options(root, name, options) do
    path = Path.join(root, name)
    File.write!(path, :erlang.term_to_binary(options))
    path
  end

  defp start_peer(options_path) do
    executable = System.find_executable("elixir") || raise "elixir executable not found"
    peer_script = Path.join(__DIR__, "distribution_smoke_peer.exs")

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:args,
         Enum.map(
           ["--erl", "-proto_dist iroh -no_epmd", "-S", "mix", "run", "--no-compile", peer_script],
           &to_charlist/1
         )},
        {:env,
         [
           {~c"MIX_ENV", ~c"prod"},
           {~c"IROH_BEAM_DISTRIBUTION_OPTIONS", to_charlist(options_path)}
         ]}
      ])

    {:ok, %{port: port, output: ""}}
  end

  defp send_data(process, data) do
    true = Port.command(process.port, data)
    {:ok, process}
  end

  defp await(process, expected, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_loop(process, expected, deadline)
  end

  defp await_loop(process, expected, deadline) do
    if String.contains?(process.output, expected) do
      {:ok, process}
    else
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {port, {:data, data}} when port == process.port ->
          await_loop(%{process | output: process.output <> data}, expected, deadline)

        {port, {:exit_status, status}} when port == process.port ->
          raise "distribution smoke peer exited #{status}: #{process.output}"
      after
        remaining -> raise "distribution smoke peer timed out waiting for #{expected}: #{process.output}"
      end
    end
  end

  defp stop(process) do
    {:ok, process} = send_data(process, "STOP\n")
    await_exit(process, System.monotonic_time(:millisecond) + 10_000)
  end

  defp await_exit(process, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {port, {:data, data}} when port == process.port ->
        await_exit(%{process | output: process.output <> data}, deadline)

      {port, {:exit_status, 0}} when port == process.port -> :ok
      {port, {:exit_status, status}} when port == process.port ->
        raise "distribution smoke peer exited #{status}: #{process.output}"
    after
      remaining -> raise "distribution smoke peer did not stop: #{process.output}"
    end
  end
end

IrohBeam.PrecompiledDistributionSmoke.run()
