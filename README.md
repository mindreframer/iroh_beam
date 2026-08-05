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

IrohBeam also provides an **optional OTP 29 Erlang distribution carrier**. It
uses Iroh as the authenticated byte transport while OTP retains cookies, the
distribution handshake and encoding, RPC, links, monitors, ticks, and node
lifecycle:

```elixir
{:ok, _net_kernel} =
  IrohBeam.Distribution.start(
    name: :"api@east",
    identity: {:file, "data/api.iroh"},
    network: :n0,
    peers: %{
      :"worker@west" =>
        {:id, System.fetch_env!("WORKER_IROH_ID")}
    }
  )

true = Node.connect(:"worker@west")
:pong = Node.ping(:"worker@west")
```

Launch an unnamed dynamic node with
`elixir --erl "-proto_dist iroh -no_epmd" ...`. Static peer configuration is
exact and immutable while running. IrohBeam does not provide membership,
automatic topology, service discovery, auto-connect, partition healing, or a
`libcluster` strategy.

Every live endpoint or distribution VM has a distinct private key. Share public
IDs, addresses, tickets, relay policy, and separately managed Erlang cookies—not
one group private key.

## Installation

```elixir
def deps do
  [
    {:iroh_beam, "~> 0.2.0"}
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
The general transport requires Elixir `~> 1.20` and NIF 2.16 support. The
optional distribution carrier is explicitly supported on OTP `29.x` only.

## Network profiles

- `:n0` uses Iroh's public relay and DNS/Pkarr defaults.
- `:direct` / `:minimal` uses IP transports with no external infrastructure.
- `:no_relay` disables relays but retains n0 address lookup/publication.
- `{:custom, relays}` uses only validated supplied relays and no public lookup.
- `direct_ip: false` forces relay-only transport for private deployments.

ID-only dialing needs lookup. Direct/custom deployments normally share an
`IrohBeam.EndpointAddr` or standard `IrohBeam.EndpointTicket`, or configure a
static address. Distribution uses the same target values in its exact peer map.

## Bounded transport and distribution

Connections expose authenticated remote IDs, negotiated ALPN, admission,
selected path, streams, datagrams, and deterministic close. Receives always
require a positive byte limit. Writes honor QUIC flow control; there is no
unbounded native queue. One operation may mutate each stream half while send and
receive remain concurrent.

Distribution keeps one native read and one flow-controlled write in flight per
link. It validates packet-four frame lengths before retaining bodies, rejects
unknown endpoint IDs and node/key mismatches before OTP, keeps normal cookies,
and does not use EPMD or a local TCP tunnel.

See the guides for [identity](docs/identity.md), [endpoints](docs/endpoints.md),
[connections](docs/connections.md), [streams](docs/streams.md),
[native distribution](docs/distribution.md),
[private relays](docs/private-relay.md), [security](docs/security.md),
[telemetry](docs/telemetry.md), and
[troubleshooting](docs/troubleshooting.md). The optional
[two-machine transport example](examples/two_machine.exs) and
[two-machine distribution example](examples/distribution_two_machine.exs)
distinguish physical-network smoke workflows from automated local proofs.

## Development

The project pins Iroh `1.0.3`, `iroh-tickets` `1.0.0`, Rustler `0.38.0`, Rust
`1.91.0`, OTP `29.x` for distribution, and NIF `2.16`. It has no dependency on
a sibling Iroh checkout.

```console
mix deps.get
docker compose up -d iroh-relay
bin/qa_check.sh
docker compose down --volumes --remove-orphans
```

## License

IrohBeam is MIT licensed. Iroh and Rustler retain their MIT/Apache-2.0 terms;
see [NOTICE](NOTICE).
