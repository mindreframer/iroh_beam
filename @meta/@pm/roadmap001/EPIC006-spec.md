# EPIC006 Spec: Private Relay and Separate-BEAM Proof

## Purpose

Prove that the embedded library connects independently running BEAM VMs through a self-hosted local Iroh relay, while using `dev_cluster` only for test orchestration and not confusing transport with Erlang clustering.

## Reference Inputs

- `@meta/@pm/ROADMAP001.md`
- EPIC003 custom relay profiles and EPIC004/005 transport API
- Official `n0computer/iroh-relay` image and Iroh relay shared-token configuration
- `dev_cluster` `0.1.0` local `:peer`/`:erpc` test lifecycle

## Scope

In scope:

- root `docker-compose.yml` with official relay image pinned by verified multi-architecture digest
- dev-mode local relay, localhost binding, readiness check, test-only shared token, isolated config/state, and explicit teardown
- QA startup/reuse, bounded readiness, diagnostics, and tagged relay integration
- `dev_cluster` as an `only: :test` dependency for separate local BEAM endpoint owners
- forced relay-only endpoint mode by disabling direct IP transports
- direct-versus-relay selected-path assertions and bounded stream exchange
- wrong/missing relay token, relay restart, endpoint restart, and reconnect tests
- runnable manual two-machine public/custom-relay smoke example

Out of scope:

- using `dev_cluster` in production or claiming it simulates physical networks/NATs
- tunneling Erlang distribution, automatic node membership, or `libcluster`
- production relay provisioning, TLS/ACME, multi-region failover, DNS/Pkarr hosting, or relay administration
- embedding the relay binary in IrohBeam

## Integration Contract

The repository owns a minimal repeatable relay fixture. The image is pinned by digest, ports bind only as documented, credentials are unmistakably test-only, and readiness has a deadline. QA may reuse a healthy container between epic gates like Parquex; it emits container status/logs on failure and documents an explicit volume-removing teardown command.

The canonical proof starts two child BEAM VMs with `dev_cluster`, starts one embedded endpoint in each, supplies distinct endpoint identities and the same custom relay URL/access token, disables direct IP transports, and exchanges bounded bytes over Iroh. Erlang distribution is only the test control plane used to start code and collect assertions. The payload path is Iroh and the selected transport must report relay.

A second direct test proves path observation can distinguish direct from forced relay operation. Manual scripts enable tests on separate machines but are not an always-on CI dependency.

## Acceptance Criteria

- Compose starts the pinned relay repeatably, reaches readiness within a bound, and uses no production credential.
- Correct shared tokens connect; missing/wrong tokens fail with stable redacted errors.
- Two separate BEAM VMs with different endpoint IDs exchange an oversized, chunked payload while direct IP transports are disabled.
- The selected path is relay for the forced test and direct for the local direct control.
- Relay restart/endpoint restart scenarios reconnect through explicit application action and leak no old resources.
- QA owns relay startup/reuse, diagnostics, tagged tests, and documented teardown.
- Docs state exactly what `dev_cluster` proves and does not prove.

## Test Strategy

- Give each test unique endpoint identities, ALPNs, operation refs, and relay-related state.
- Use `dev_cluster` controller cleanup and explicit remote endpoint close; collect remote coverage where supported.
- Assert selected path and byte counts, not timing or NAT behavior.
- Restart the relay at controlled boundaries and retry only from the application test.
- Scan compose output, errors, logs, telemetry, and child-node output for the test token.
- Keep optional public/two-machine smoke tests outside the default QA network contract.

## Quality Bar

- Default integration needs only Docker and loopback, never public Iroh infrastructure.
- The relay image/version/digest and test access policy are reproducible.
- Separate-BEAM tests cannot pass without explicit Iroh send/receive calls and relay path evidence.
- Test orchestration does not become a product cluster abstraction.
- Full QA is green before commit.
