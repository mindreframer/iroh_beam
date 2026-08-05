# Private relay and separate-BEAM testing

The root `docker-compose.yml` runs the official multi-architecture
`n0computer/iroh-relay:v1.0.3` image pinned to OCI index digest
`sha256:e9a7ba14287dd9693aca61c339b0d154456d6609f3818a0ef358b07b36aab9cc`.
It binds development HTTP and metrics ports to localhost only and uses an
unmistakably non-production shared token.

```console
docker compose up -d iroh-relay
curl --fail http://127.0.0.1:3340/
```

Explicit teardown, including Compose-created state, is:

```console
docker compose down --volumes --remove-orphans
```

QA starts or reuses the relay, waits up to 45 seconds, runs tagged relay tests,
and prints container state and the last 200 log lines on failure. Public Iroh
infrastructure is not part of this integration contract.

## Relay-only endpoint

```elixir
{:ok, relay} =
  IrohBeam.Relay.new("http://127.0.0.1:3340",
    token: "iroh-beam-local-test-token-not-for-production"
  )

{:ok, endpoint} =
  IrohBeam.Endpoint.start_link(
    identity: {:file, "data/private-relay.identity"},
    alpns: ["my-app/1"],
    network: {:custom, [relay]},
    direct_ip: false
  )

:ok = IrohBeam.Endpoint.await_online(endpoint)
```

`direct_ip: false` removes IP transports rather than merely preferring a relay.
Successful forced tests require `Connection.path/1` to report `:relay`. Missing
or wrong tokens fail relay admission and are never included in errors, status,
logs, or inspection.

## What the separate-BEAM test proves

`dev_cluster` is a **test-only control-plane helper**. It starts two real local
BEAM VMs so the suite can prove that endpoint identities, runtimes, resources,
and owners are not process-global. Each child creates a different private key,
disables direct IP, connects to the local relay, and sends a multi-megabyte
bounded stream through Iroh. The manager receives only commands, byte counts,
hashes, and path evidence over Erlang distribution.

That ROADMAP001 test does **not** tunnel Erlang distribution, simulate NATs, or
simulate physical machines. ROADMAP002 adds a separate three-OS-process test
that carries native OTP distribution through Iroh with `-proto_dist iroh`; it
still does not provide membership or simulate a production relay topology. Use
`examples/two_machine.exs` for an application-transport smoke test and
`examples/distribution_two_machine.exs` for the optional native-distribution
workflow.
