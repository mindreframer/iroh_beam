# Supervised endpoints and network profiles

An `IrohBeam.Endpoint` is one OTP child and one native Iroh endpoint. It is not a
VM-global singleton. Every concurrently live endpoint needs a distinct private
identity.

```elixir
{:ok, endpoint} =
  IrohBeam.Endpoint.start_link(
    identity: {:file, "data/iroh.identity"},
    alpns: ["my-app/1"],
    network: :direct,
    bind: ["127.0.0.1:0"]
  )

{:ok, endpoint_id} = IrohBeam.Endpoint.id(endpoint)
{:ok, endpoint_addr} = IrohBeam.Endpoint.addr(endpoint)
:ok = IrohBeam.Endpoint.close(endpoint)
```

Use the child specification under a supervisor. Normal explicit close does not
restart the child; abnormal owner death does. Persistent identity is retained
only when `identity: {:file, path}` or an explicit `SecretKey` is configured.

## Profiles

| Profile | IP transports | Relay | Address lookup/publication |
| --- | --- | --- | --- |
| `:n0` | yes | n0 public defaults | n0 DNS/Pkarr defaults |
| `:direct` / `:minimal` | yes | disabled | disabled |
| `:no_relay` | yes | disabled | n0 DNS/Pkarr defaults |
| `{:custom, relays}` | yes | supplied records only | disabled |

`:direct` is the infrastructure-free profile. It does not silently contact a
public relay or address-lookup service. Peers will need an explicit endpoint
address or ticket. `:no_relay` is different: it retains n0 lookup/publication and
therefore can contact public infrastructure.

A custom relay record validates its HTTP(S) URL and optional bearer token before
native bind. Tokens cannot be placed in URL credentials or query strings and are
redacted from inspection, status, errors, logs, and native info.

```elixir
{:ok, relay} = IrohBeam.Relay.new("https://relay.internal.example./", token: token)

{:ok, endpoint} =
  IrohBeam.Endpoint.start_link(
    identity: :ephemeral,
    alpns: ["my-app/1"],
    network: {:custom, [relay]},
    bind: ["0.0.0.0:0"]
  )
```

`bind` accepts at most one socket per IP family. Port `0` asks the OS for an
available port. Startup and shutdown timeouts are positive milliseconds.
`limits` currently validates `:max_pending_accepts` and `:max_connections`; the
connection layer consumes these bounds.
