defmodule IrohBeam.DistributionPeerScript do
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
