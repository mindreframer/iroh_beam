# IrohBeam

IrohBeam embeds [Iroh](https://iroh.computer/) in Elixir applications as a
small, supervised, authenticated QUIC transport. Peers dial stable key-derived
endpoint IDs while Iroh handles changing IP paths, hole punching, and relays.

```elixir
{:ok, endpoint} =
  IrohBeam.Endpoint.start_link(
    identity: {:file, "data/iroh.identity"},
    alpns: ["my-app/1"],
    network: :n0
  )

peer_id = IrohBeam.EndpointId.parse!(System.fetch_env!("PEER_ID"))
{:ok, connection} = IrohBeam.Endpoint.connect(endpoint, peer_id, "my-app/1")
{:ok, stream} = IrohBeam.Connection.open_bi(connection)
:ok = IrohBeam.Stream.send(stream, "hello")
:ok = IrohBeam.Stream.finish(stream)
{:ok, reply} = IrohBeam.Stream.recv(stream, 64 * 1024)
```

IrohBeam is **not Erlang distribution**. It does not replace EPMD, form a BEAM
cluster, provide membership or RPC, or call `Node.connect/1`. Applications own
an explicit ALPN and protocol. Every live endpoint has a distinct private key;
share public IDs, addresses, tickets, or relay policy—not one group private key.

## Installation

```elixir
def deps do
  [
    {:iroh_beam, "~> 0.1.0"}
  ]
end
```

Supported precompiled NIF 2.16 targets:

- macOS ARM64 and x86_64;
- Linux ARM64/x86_64 GNU;
- Linux ARM64/x86_64 musl;
- Windows x86_64 MSVC.

A clean supported consumer downloads a verified archive and does not invoke
Cargo. Source builds require Rust `1.91.0`; set `IROH_BEAM_BUILD=1` to force one.
The library requires Elixir `~> 1.20` and OTP with NIF 2.16 support.

## Network profiles

- `:n0` uses Iroh's public relay and DNS/Pkarr defaults.
- `:direct` / `:minimal` uses IP transports with no external infrastructure.
- `:no_relay` disables relays but retains n0 address lookup/publication.
- `{:custom, relays}` uses only validated supplied relays and no public lookup.
- `direct_ip: false` forces relay-only transport for private deployments.

ID-only dialing needs lookup. Direct/custom deployments normally share an
`IrohBeam.EndpointAddr` or standard `IrohBeam.EndpointTicket`, or configure a
static address book.

## Bounded transport

Connections expose authenticated remote IDs, negotiated ALPN, admission,
selected path, streams, datagrams, and deterministic close. Receives always
require a positive byte limit. Writes honor QUIC flow control; there is no
unbounded native queue. One operation may mutate each stream half while send and
receive remain concurrent.

See the guides for [identity](docs/identity.md), [endpoints](docs/endpoints.md),
[connections](docs/connections.md), [streams](docs/streams.md),
[private relays](docs/private-relay.md), [security](docs/security.md),
[telemetry](docs/telemetry.md), and [troubleshooting](docs/troubleshooting.md).
The optional [two-machine example](examples/two_machine.exs) distinguishes a
physical-network smoke test from the local separate-BEAM control-plane proof.

## Development

The project pins Iroh `1.0.3`, `iroh-tickets` `1.0.0`, Rustler `0.38.0`, Rust
`1.91.0`, and NIF `2.16`. It has no dependency on a sibling Iroh checkout.

```console
mix deps.get
docker compose up -d iroh-relay
bin/qa_check.sh
docker compose down --volumes --remove-orphans
```

## License

IrohBeam is MIT licensed. Iroh and Rustler retain their MIT/Apache-2.0 terms;
see [NOTICE](NOTICE).
