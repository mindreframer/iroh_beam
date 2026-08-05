defmodule IrohBeam.DistributionPeerScript do
  def echo(value), do: value

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

          "PING" ->
            IO.puts(["PING ", inspect(Node.ping(peer))])
            loop(peer)

          "RPC" ->
            result = :rpc.call(peer, :erlang, :node, [])
            IO.puts(["RPC ", inspect(result)])
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
IO.puts(["PEER_READY ", Atom.to_string(Node.self()), " ", to_string(status.endpoint_id)])
IrohBeam.DistributionPeerScript.loop(peer)
