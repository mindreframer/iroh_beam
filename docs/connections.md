# Authenticated connections and admission

Dial an endpoint with a public ID, explicit address, or standard ticket and one
application ALPN:

```elixir
{:ok, connection} =
  IrohBeam.Endpoint.connect(endpoint, peer_addr, "my-app/1", timeout: 5_000)

remote_id = IrohBeam.Connection.remote_id(connection)
{:ok, %{kind: path_kind}} = IrohBeam.Connection.path(connection)
```

An ID alone contains no network path. `:n0` can resolve IDs through its configured
public lookup. Infrastructure-free endpoints need an explicit `EndpointAddr`, an
`EndpointTicket`, or a static `address_book` entry configured on the dialing
endpoint. IrohBeam never falls back from `:direct` or `{:custom, ...}` to public
lookup.

Incoming acceptance is pull-based and bounded:

```elixir
{:ok, incoming} = IrohBeam.Endpoint.accept(endpoint, timeout: 30_000)
```

Only one accept demand is pending per endpoint; competing demand returns `:busy`
rather than forming an unbounded queue. `limits: [max_connections: n]` bounds
successful native connection resources. Timeouts and caller death cancel the
pending handshake or accept without affecting unrelated connections.

Set `peer_allowlist: [endpoint_id, ...]` on endpoint startup to admit only those
authenticated remote identities. The check runs after the cryptographic Iroh
handshake and before a successful `accept/2` is returned. `:all` is the default.

Connections expose remote ID, negotiated ALPN, client/server side, stable ID,
selected direct/relay path and RTT, explicit close, close state, and a bounded
closed wait. Peer-provided close text and unstable native errors are not exposed
as safe log context.
