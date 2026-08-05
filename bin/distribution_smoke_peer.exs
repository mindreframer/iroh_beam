defmodule IrohBeam.DistributionSmokePeer do
  def loop(peer) do
    case IO.gets("") do
      :eof -> stop()
      {:error, _reason} -> stop()
      line -> command(String.trim(line), peer)
    end
  end

  defp command("CONNECT", peer) do
    IO.puts(["CONNECT ", inspect(connect_with_retry(peer, 5))])
    loop(peer)
  end

  defp command("PING", peer) do
    result = {Node.ping(peer), :rpc.call(peer, :erlang, :node, [])}
    IO.puts(["PING ", inspect(result)])
    loop(peer)
  end

  defp connect_with_retry(peer, attempts) do
    case Node.connect(peer) do
      true -> true
      false when attempts > 1 ->
        Process.sleep(100)
        connect_with_retry(peer, attempts - 1)
      false -> false
    end
  end

  defp command("STOP", _peer), do: stop()
  defp command(_other, peer), do: loop(peer)

  defp stop do
    _ = IrohBeam.Distribution.stop()
    IO.puts("STOPPED")
  end
end

options =
  System.fetch_env!("IROH_BEAM_DISTRIBUTION_OPTIONS")
  |> File.read!()
  |> :erlang.binary_to_term()

peer = options |> Keyword.fetch!(:peers) |> Map.keys() |> List.first()
{:ok, _pid} = IrohBeam.Distribution.start(options)
Node.set_cookie(:iroh_beam_precompiled_smoke_cookie)
IO.puts(["READY ", Atom.to_string(Node.self())])
IrohBeam.DistributionSmokePeer.loop(peer)
