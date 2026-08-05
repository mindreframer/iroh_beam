{:ok, %{iroh: "1.0.3", nif: "2.16", crate_version: "0.2.0"}} = IrohBeam.native_versions()
{:ok, secret_key} = IrohBeam.SecretKey.generate()
{:ok, endpoint_id} = IrohBeam.SecretKey.endpoint_id(secret_key)
{:ok, same_id} = endpoint_id |> to_string() |> IrohBeam.EndpointId.parse()
true = endpoint_id == same_id
{:ok, addr} = IrohBeam.EndpointAddr.new(endpoint_id, ip_addrs: ["127.0.0.1:443"])
{:ok, ticket} = IrohBeam.EndpointTicket.new(addr)
{:ok, ^ticket} = ticket |> to_string() |> IrohBeam.EndpointTicket.parse()
{:ok, config} =
  IrohBeam.Distribution.Config.validate(
    name: :"consumer@host",
    identity: :ephemeral,
    network: :direct,
    peers: %{}
  )

true = config.name == :"consumer@host"
IO.puts("Precompiled public and distribution configuration smoke passed")
