# IrohBeam

IrohBeam embeds [Iroh](https://iroh.computer/) in Elixir applications as a
small, supervised transport library. Peers authenticate with key-derived
endpoint IDs and communicate through explicit application ALPNs.

ROADMAP001 is implemented in dependency order. The current foundation proves
that the Rustler NIF loads and that cancellable asynchronous work runs on a
managed native Tokio runtime without blocking normal BEAM schedulers.

```elixir
{:ok, versions} = IrohBeam.native_versions()
{:ok, :completed} = IrohBeam.native_smoke()
```

IrohBeam is **not Erlang distribution**: it does not replace EPMD, form a BEAM
cluster, provide membership or RPC, or call `Node.connect/1`. A future endpoint
private key belongs to one concurrently live endpoint; applications share public
endpoint IDs, endpoint tickets, or relay access policy instead of reusing a
private identity as a group key.

## Development

The project pins Iroh `1.0.3`, Rustler `0.38.0`, Rust `1.91.0`, and NIF `2.16`.
It has no dependency on a sibling Iroh checkout.

```console
mix deps.get
bin/qa_check.sh
```

Architecture decisions are recorded in [`docs/architecture`](docs/architecture).
