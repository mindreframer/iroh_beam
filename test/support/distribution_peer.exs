defmodule IrohBeam.DistributionPeerScript do
  def echo(value), do: value

  def start_waiter do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  def crash do
    Process.sleep(50)
    exit(:distribution_test_crash)
  end

  def registered_loop do
    receive do
      {from, reference, value} ->
        send(from, {reference, value})
        registered_loop()
    end
  end

  def loop(peer) do
    case IO.gets("") do
      :eof ->
        stop()

      {:error, _reason} ->
        stop()

      line ->
        case String.trim(line) do
          "CONNECT" ->
            result = Node.connect(peer)
            IO.puts(["CONNECT ", inspect(result), " ", inspect(Enum.sort(Node.list()))])
            loop(peer)

          "LIST" ->
            IO.puts(["LIST ", inspect(Enum.sort(Node.list()))])
            loop(peer)

          "INFO" ->
            result = IrohBeam.Distribution.peer_info(peer)
            IO.puts(["INFO ", inspect(result)])
            loop(peer)

          "COUNTERS" ->
            {:ok, %{link: link}} = IrohBeam.Distribution.peer_info(peer)

            valid =
              link.bytes_sent > 0 and link.bytes_received > 0 and
                link.frames_sent > 0 and link.frames_received > 0

            IO.puts(["COUNTERS ", inspect(valid), " ", inspect(link)])
            loop(peer)

          "PING" ->
            IO.puts(["PING ", inspect(Node.ping(peer))])
            loop(peer)

          "RPC" ->
            result = :rpc.call(peer, :erlang, :node, [])
            IO.puts(["RPC ", inspect(result)])
            loop(peer)

          "RPC_ERROR" ->
            result = :rpc.call(peer, :erlang, :error, [:remote_boom])
            IO.puts(["RPC_ERROR ", inspect(match?({:badrpc, _}, result))])
            loop(peer)

          "REGISTERED" ->
            reference = make_ref()
            send({:iroh_dist_registered, peer}, {self(), reference, "registered-ok"})

            result =
              receive do
                {^reference, value} -> value
              after
                5_000 -> :timeout
              end

            IO.puts(["REGISTERED ", inspect(result)])
            loop(peer)

          "MONITOR" ->
            pid = :rpc.call(peer, __MODULE__, :start_waiter, [])
            reference = Process.monitor(pid)
            true = :rpc.call(peer, :erlang, :exit, [pid, :kill])

            result =
              receive do
                {:DOWN, ^reference, :process, ^pid, reason} -> reason
              after
                5_000 -> :timeout
              end

            IO.puts(["MONITOR ", inspect(result)])
            loop(peer)

          "LINK" ->
            old = Process.flag(:trap_exit, true)
            pid = Node.spawn_link(peer, __MODULE__, :crash, [])

            result =
              receive do
                {:EXIT, ^pid, reason} -> reason
              after
                5_000 -> :timeout
              end

            Process.flag(:trap_exit, old)
            IO.puts(["LINK ", inspect(result)])
            loop(peer)

          "DISCONNECT" ->
            :net_kernel.monitor_nodes(true)
            result = Node.disconnect(peer)

            event =
              receive do
                {:nodedown, ^peer} -> :nodedown
                {:nodedown, ^peer, _info} -> :nodedown
              after
                5_000 -> :timeout
              end

            :net_kernel.monitor_nodes(false)

            IO.puts([
              "DISCONNECT ",
              inspect(result),
              " ",
              inspect(event),
              " ",
              inspect(Node.list())
            ])

            loop(peer)

          "FAULT" ->
            result = :iroh_dist_endpoint.close_link(peer)
            Process.sleep(100)
            IO.puts(["FAULT ", inspect(result), " ", inspect(Node.list())])
            loop(peer)

          "LARGE" ->
            payload = :binary.copy(<<0xA5>>, 2 * 1024 * 1024)
            result = :rpc.call(peer, __MODULE__, :echo, [payload], 15_000)

            IO.puts([
              "LARGE ",
              inspect(result == payload),
              " ",
              Integer.to_string(byte_size(result))
            ])

            loop(peer)

          "IDLE" ->
            Process.sleep(5_000)
            IO.puts(["IDLE ", inspect(Node.ping(peer))])
            loop(peer)

          "BURST" ->
            results =
              1..32
              |> Task.async_stream(
                fn index -> :rpc.call(peer, __MODULE__, :echo, [index], 5_000) end,
                max_concurrency: 8,
                timeout: 10_000
              )
              |> Enum.map(fn {:ok, value} -> value end)

            IO.puts(["BURST ", inspect(results == Enum.to_list(1..32))])
            loop(peer)

          "STOP" ->
            stop()

          _ ->
            IO.puts("UNKNOWN_COMMAND")
            loop(peer)
        end
    end
  end

  defp stop do
    _ = IrohBeam.Distribution.stop()
    IO.puts("PEER_STOPPED")
  end
end

options_path = System.fetch_env!("IROH_BEAM_DISTRIBUTION_OPTIONS")
options = options_path |> File.read!() |> :erlang.binary_to_term()
peer = options |> Keyword.fetch!(:peers) |> Map.keys() |> List.first()

{:ok, _pid} = IrohBeam.Distribution.start(options)

if cookie = System.get_env("IROH_BEAM_DISTRIBUTION_COOKIE") do
  Node.set_cookie(String.to_atom(cookie))
end

{:ok, status} = IrohBeam.Distribution.status()
registered = spawn(&IrohBeam.DistributionPeerScript.registered_loop/0)
Process.register(registered, :iroh_dist_registered)
IO.puts(["PEER_READY ", Atom.to_string(Node.self()), " ", to_string(status.endpoint_id)])
IrohBeam.DistributionPeerScript.loop(peer)
