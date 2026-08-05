defmodule IrohBeam.Examples.DistributionTwoMachine do
  @moduledoc false

  alias IrohBeam.{Distribution, EndpointId, Relay}

  def main do
    local_node = required_atom!("IROH_BEAM_NODE")
    peer_node = required_atom!("IROH_BEAM_PEER_NODE")
    peer_id = EndpointId.parse!(System.fetch_env!("IROH_BEAM_PEER_ID"))
    identity = System.get_env("IROH_BEAM_IDENTITY", "data/#{local_node}.iroh")

    {network, target, direct_ip} = network_and_target(peer_id)

    {:ok, _pid} =
      Distribution.start(
        name: local_node,
        name_domain: name_domain(local_node),
        identity: {:file, identity},
        network: network,
        direct_ip: direct_ip,
        peers: %{peer_node => target}
      )

    # In a release, set the cookie through the VM's normal secret mechanism.
    if cookie = System.get_env("IROH_BEAM_COOKIE") do
      Node.set_cookie(String.to_atom(cookie))
    end

    connected? = Node.connect(peer_node)
    ping = Node.ping(peer_node)
    rpc = if connected?, do: :rpc.call(peer_node, :erlang, :node, []), else: :not_connected
    info = Distribution.peer_info(peer_node)

    IO.inspect(%{connected?: connected?, ping: ping, rpc_node: rpc, peer: info})
    Process.sleep(:infinity)
  end

  defp network_and_target(peer_id) do
    case System.get_env("IROH_BEAM_RELAY_URL") do
      nil ->
        {:n0, peer_id, true}

      url ->
        relay_options =
          case System.get_env("IROH_BEAM_RELAY_TOKEN") do
            nil -> []
            token -> [token: token]
          end

        {:ok, relay} = Relay.new(url, relay_options)

        target =
          {:addr,
           %{
             endpoint_id: to_string(peer_id),
             relay_urls: [url],
             ip_addrs: []
           }}

        {{:custom, [relay]}, target, false}
    end
  end

  defp required_atom!(environment) do
    environment
    |> System.fetch_env!()
    |> String.to_atom()
  end

  defp name_domain(node) do
    [_name, host] = node |> Atom.to_string() |> String.split("@")
    if String.contains?(host, "."), do: :longnames, else: :shortnames
  end
end

IrohBeam.Examples.DistributionTwoMachine.main()
