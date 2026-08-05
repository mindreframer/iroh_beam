# ROADMAP001 — Embedded Iroh Transport for Elixir

- **Status:** Planned
- **Target release:** `0.1.0`
- **Primary interface:** Elixir/OTP
- **Native implementation:** Rust via Rustler, embedded in the BEAM
- **Pinned upstream baseline:** Iroh `1.0.3`, Rust `1.91`, NIF `2.16`

## 1. Product Goal

IrohBeam brings Iroh's "IP addresses break, dial keys instead" model to Elixir applications as a small, supervised transport library.

The common path must be recognizably Elixir:

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

For private or air-gapped deployments, the same endpoint API accepts explicit addresses or endpoint tickets and a custom self-hosted relay profile. Applications may use public Iroh address lookup, their own coordination mechanism, or share tickets; IrohBeam does not force a control plane.

## 2. Research Conclusions and Decisions

### Embed Iroh; do not start a sidecar

The initial implementation is an embedded Rustler NIF. Iroh is designed as an embeddable Rust library, its official FFI embeds the runtime in Python, Swift, Kotlin, and JavaScript applications, and Parquex already proves the repository's Rustler/precompiled-NIF process. A sidecar would add process supervision, IPC framing, binary deployment, duplicated buffering, and a second failure protocol before the transport itself is proven.

The native boundary must nevertheless be conservative:

- one managed Tokio runtime per loaded NIF;
- NIF entry points return quickly and never call `Runtime::block_on` while occupying a BEAM scheduler;
- asynchronous operations complete by reference-tagged messages to Elixir;
- caller/owner death and timeout cancel native work;
- resources are explicitly closeable and also safe on drop;
- panics are contained and translated wherever recovery is possible.

A sidecar remains a future opt-in backend if real fault-containment evidence justifies its operational cost. It is not built speculatively in this roadmap.

### Iroh transport is not Erlang distribution

IrohBeam initially exposes authenticated QUIC endpoints, connections, streams, and datagrams. It does not call `Node.connect/1`, replace EPMD, form a BEAM cluster, provide a `libcluster` strategy, or tunnel Erlang distribution. Applications communicate through an explicit application ALPN and protocol.

`dev_cluster` is useful only as a **test dependency**. It will prove that independently supervised endpoints work in separate local BEAM VMs and that native resources are not accidentally process-global. It is not a product dependency and cannot prove NAT traversal or physical-network isolation by itself. Relay-only integration tests and a pinned local relay provide the transport proof; optional manual two-machine examples provide the physical-network smoke path.

### Identity keys are per endpoint

Every simultaneously running endpoint must have its own Iroh `SecretKey`; its public half is the `EndpointId` that peers dial. Two endpoints must not share one private identity key. Doing so creates an identity collision rather than a cluster.

What applications share depends on the deployment:

- share **Endpoint IDs** when address lookup can resolve them;
- share **Endpoint Tickets** or explicit endpoint addresses when lookup is unavailable;
- optionally share a **relay access token** to admit a group to a private relay;
- use distinct endpoint keys and an explicit peer allowlist for application admission.

This distinction is part of the public contract and documentation.

### Start with the stable Iroh 1.0 core

The first release follows the stable core surface also used by the official Iroh FFI: endpoint identity/address/tickets, endpoint lifecycle, custom relays, authenticated connections, QUIC streams, datagrams, and selected path information. `iroh-gossip`, `iroh-blobs`, `iroh-docs`, custom transports, and unstable network-report APIs are deferred.

The local sibling checkout is a research reference only. The package and CI pin crates.io dependencies and never depend on `/Users/.../iroh` or another checkout.

## 3. Public Model

```text
SecretKey -> EndpointId
Endpoint + (EndpointId | EndpointAddr | EndpointTicket) + ALPN -> Connection
Connection -> uni stream | bi stream | datagram
custom Relay profile -> private reachability and relay fallback
```

Initial public modules:

- `IrohBeam`: concise delegates and product documentation.
- `IrohBeam.Identity`: generation, parsing, redacted representation, and optional file-backed persistence.
- `IrohBeam.SecretKey` and `IrohBeam.EndpointId`: private/public identity values.
- `IrohBeam.EndpointAddr` and `IrohBeam.EndpointTicket`: explicit dialing information.
- `IrohBeam.Relay`: validated, redacted relay configuration.
- `IrohBeam.Endpoint`: supervised endpoint lifecycle, dialing, and pull-based acceptance.
- `IrohBeam.Connection`: authenticated connection lifecycle, stream creation/acceptance, datagrams, and path snapshot.
- `IrohBeam.Stream`: bounded send/receive and QUIC finish/reset/stop semantics.
- `IrohBeam.Error`: stable error categories with operation context.
- `IrohBeam.Telemetry`: documented safe event contract.

The default layer stays small. Advanced options remain explicit keyword options and typed value modules rather than a second native-shaped API.

## 4. In Scope

- Embedded Rustler NIF using Iroh crates pinned exactly to `1.0.3`.
- A supervised, restartable Elixir endpoint process with explicit ownership.
- Persistent and ephemeral endpoint identities.
- Endpoint IDs, endpoint addresses, and standard endpoint tickets.
- `:n0`, infrastructure-free/direct, and custom-relay network profiles.
- Relay URLs and bearer/shared-token client configuration with redaction.
- ALPN-authenticated outgoing and incoming connections.
- Optional endpoint peer allowlists based on authenticated endpoint IDs.
- Bidirectional and unidirectional QUIC streams.
- Explicitly bounded reads, backpressured writes, finish/reset/stop, and datagrams.
- Cancellation on timeout, caller death, owner death, explicit close, and stream abort.
- Local direct tests, local private-relay tests, separate-BEAM tests, and repeatable QA.
- Telemetry, documentation, package metadata, and precompiled NIF release artifacts.

## 5. Explicitly Deferred

- Erlang distribution over Iroh, EPMD replacement, automatic BEAM clustering, and a `libcluster` strategy.
- Membership, leader election, service discovery, RPC, request framing, serialization, or application protocol design.
- Group identity based on reusing one endpoint private key.
- Bundling or supervising a production relay inside the application.
- A sidecar transport backend.
- Self-hosted DNS/Pkarr service orchestration and a custom address-lookup plugin API.
- `iroh-gossip`, `iroh-blobs`, `iroh-docs`, and other higher-level protocols.
- Unstable custom transports, unstable net-report APIs, and post-quantum policy controls.
- Stream priority, 0-RTT, dynamic relay mutation, proxy configuration, platform certificate-store customization, and every upstream tuning knob.

Deferred features may be added in later roadmaps without changing the core identity/endpoint/connection/stream model.

## 6. Runtime, Memory, and Lifecycle Invariants

1. No network wait, endpoint bind, handshake, accept, stream read/write, or shutdown blocks a normal BEAM scheduler.
2. Every async native operation has a unique reference, one terminal result, cancellation, and late-result suppression.
3. A receive allocation is bounded by a caller-supplied positive byte limit; there is no unbounded `read_to_end` API.
4. Writes honor QUIC flow control and do not use an unbounded native queue.
5. At most one mutable operation is in flight on each send or receive half; conflicting use fails clearly rather than deadlocking.
6. Send and receive halves of a bidirectional stream can make progress concurrently.
7. Endpoint owner death, endpoint close, or application shutdown cancels accepts and connections and drains native tasks within a bounded deadline.
8. Caller death or timeout cancels that caller's pending operation and does not deliver an orphaned result.
9. Explicit close is deterministic; garbage collection is only a final safety net.
10. Secrets and relay tokens never appear in `Inspect`, errors, logs, telemetry, crash reports, or test output.
11. Rust panics and upstream error hierarchies never become VM crashes or unstable public return shapes on tested paths.
12. Multiple endpoints and multiple BEAM VMs do not share endpoint identity or mutable endpoint state unless the caller explicitly supplies it.

## 7. Quality and Commit Policy

`bin/qa_check.sh` is the authoritative epic gate and mirrors the proven Parquex process. It grows with the roadmap and ultimately covers:

- locked Mix dependencies, formatting, warnings-as-errors compilation, ExUnit, docs, and package checks;
- Rust formatting, locked checks, Clippy with warnings denied, and Rust tests;
- pinned Docker Compose configuration, local relay readiness, diagnostics, and integration tests;
- direct, relay-only, multi-BEAM, cancellation, resource, scheduler, and bounded-memory tests;
- clean no-Rust precompiled-consumer smoke tests.

Every epic must:

1. Complete every phase and acceptance criterion in its spec and plan.
2. Run `bin/qa_check.sh` and fix every failure.
3. Review the diff for unrelated changes, generated artifacts, credentials, and stale concepts.
4. Update only completed plan checkboxes.
5. Commit the green epic as `roadmap001 - epic N - <outcome>` with an informative body that states the result and verification.

GitHub actions, toolchains, relay images, and release inputs are pinned. CI invokes `bin/qa_check.sh` instead of maintaining a second logic path. The precompiled release pipeline follows Parquex's NIF `2.16` seven-target process and verifies the exact artifact set before publication.

---

## Epic 1 — Embedded Native Foundation and Reproducible QA

**Objective:** Prove that embedding current Iroh in the BEAM is viable and establish the native runtime and quality contracts before networking features accumulate.

Deliverables:

- Rustler crate pinned to Iroh `1.0.3` and Rust `1.91`.
- Fast and asynchronous boundary smoke calls with translated errors.
- Runtime, resource, cancellation, panic, scheduler, and sidecar ADRs.
- Parquex-style local QA and pinned CI foundations.

Acceptance:

- The NIF loads in-process and an asynchronous operation completes without blocking a normal scheduler.
- Owner/caller cancellation crosses the boundary and leaves no native task.
- The crate is independent of the sibling Iroh checkout.
- `bin/qa_check.sh` is green and no endpoint/network behavior is introduced prematurely.

## Epic 2 — Identity, Addresses, and Tickets

**Objective:** Make stable key-based identity safe and easy before opening sockets.

Deliverables:

- Secret key and endpoint ID generation/parsing.
- Endpoint address and standard endpoint-ticket values.
- Optional atomic file-backed identity persistence.
- Redacted inspection, stable validation, and identity guidance.

Acceptance:

- Restarting from one identity file produces the same endpoint ID.
- Independent identities produce different IDs, and private bytes never leak.
- Address/ticket text and bytes round-trip against upstream Iroh.
- Documentation clearly rejects concurrent reuse of one private endpoint identity.

## Epic 3 — Supervised Endpoints and Network Profiles

**Objective:** Bind embedded Iroh endpoints under OTP supervision with a small common configuration and an advanced explicit path.

Deliverables:

- `IrohBeam.Endpoint.start_link/1`, child specification, close, status, ID, address, and online operations.
- `:n0`, direct/minimal, disabled-relay, and custom-relay profiles.
- Validated bind addresses, ALPNs, relay URLs, auth tokens, timeouts, and limits.
- Deterministic endpoint owner-death and restart cleanup.

Acceptance:

- Multiple supervised endpoints can coexist with isolated identities and configuration.
- Direct/minimal startup performs no external address-lookup or relay access.
- Custom relay tokens are redacted on every observable path.
- Endpoint shutdown and supervisor restart leave no sockets or native tasks owned by the old endpoint.

## Epic 4 — Authenticated Connections and Admission

**Objective:** Dial peers by stable identity/address information and accept authenticated ALPN connections without imposing an application protocol.

Deliverables:

- Dialing by endpoint ID, endpoint address, or endpoint ticket with documented lookup requirements.
- Pull-based incoming connection acceptance and ALPN negotiation.
- Remote endpoint identity, close semantics, selected path snapshot, and optional peer allowlist.
- Timeout, cancellation, refusal, malformed-peer, and owner-exit behavior.

Acceptance:

- Two local endpoints connect directly and mutually observe the expected endpoint IDs and ALPN.
- ID-only dialing succeeds when lookup is configured and fails clearly when no dialing information can be resolved.
- An unlisted authenticated peer is rejected without reaching application handling.
- Cancelled or failed handshakes leave no pending native operation or connection resource.

## Epic 5 — Bounded QUIC Streams and Datagrams

**Objective:** Expose Iroh's useful QUIC transport primitives with Elixir-friendly bounded I/O and clear closure semantics.

Deliverables:

- Uni- and bidirectional stream open/accept operations.
- Bounded send/receive, EOF, finish, reset, stop, and stream IDs.
- Datagram send/receive with size and capacity validation.
- Backpressure, half-level concurrency rules, cancellation, and large-transfer tests.

Acceptance:

- Echo and request/response examples work over reusable connections.
- Payloads much larger than configured chunks transfer without unbounded queues or scheduler stalls.
- Send and receive can proceed concurrently while conflicting operations on one half fail deterministically.
- Stream/connection aborts unblock waiting callers and return stable errors.

## Epic 6 — Private Relay and Separate-BEAM Proof

**Objective:** Prove private-network operation through a locally runnable relay and distinguish transport testing from BEAM clustering.

Deliverables:

- Root Docker Compose service using the official Iroh relay image pinned by digest.
- Shared-token relay fixture and redacted custom-relay endpoint profile.
- Test-only `dev_cluster` integration for separate local BEAM VMs.
- Direct and forced relay-only proofs, plus a manual two-machine example.

Acceptance:

- Two distinct endpoint identities in separate BEAM VMs exchange bounded stream data through the local relay with direct IP transports disabled.
- Relay access succeeds with the shared relay token and fails with a wrong token without disclosure.
- QA starts or reuses the relay, waits with a bound, emits diagnostics on failure, and documents explicit teardown.
- Tests and docs make no claim that `dev_cluster` simulates NATs, physical machines, or an Iroh-backed Erlang cluster.

## Epic 7 — Hardening, Observability, Packaging, and `0.1.0`

**Objective:** Freeze the focused API, prove failure behavior, and release precompiled binaries consumable without Rust.

Deliverables:

- Stable errors and safe telemetry for endpoint, connection, path, stream, byte, duration, and cancellation events.
- Fault, lifecycle, resource-plateau, memory, and scheduler responsiveness coverage.
- Runnable guides for public, direct, ticket, and self-hosted-relay workflows.
- Synchronized package metadata, licenses/notices, docs, changelog, version, and precompiled release workflow.
- Seven validated NIF `2.16` archives, published checksums, and no-Rust consumer verification.

Acceptance:

- All documented examples execute in tests and full QA passes from a clean checkout.
- Errors, logs, telemetry, docs, fixtures, and package contents contain no private keys or relay tokens.
- The exact seven-target release set is smoke-tested before publication and clean consumers never invoke Cargo.
- Release tag, artifacts, SHA-256 manifest, Hex package/docs, consumer CI, and final CI are all verified green before the roadmap is marked complete.

## 8. Dependency Order

```text
Epic 1: embedded foundation + QA
   -> Epic 2: identity + dialing values
   -> Epic 3: supervised endpoints + networks
   -> Epic 4: authenticated connections
   -> Epic 5: streams + datagrams
   -> Epic 6: private relay + separate-BEAM proof
   -> Epic 7: hardening + precompiled release
```

## 9. Initial Technical Direction

- `rustler` and `rustler_precompiled` mirror the proven Parquex native-loading pattern.
- `iroh = 1.0.3` is pinned from crates.io with the smallest feature set that supports core endpoints, metrics required by the public telemetry contract, custom relays, and the selected TLS provider.
- `iroh-tickets` is used for the standard endpoint-ticket encoding rather than creating a package-specific ticket format.
- Tokio runs native networking on managed background threads; Rustler NIF functions submit bounded work and return immediately.
- Rustler resources wrap endpoint, connection, send-stream, and receive-stream ownership. Elixir endpoint processes own endpoint resources and operation registries.
- Native completions use unforgeable operation references and `OwnedEnv`; Elixir discards late replies after cancellation.
- Public calls return `{:ok, value}` / `{:error, %IrohBeam.Error{}}`; bang variants are limited to pure parsing/construction helpers.
- Telemetry is optional and handler failures never affect transport correctness.
- The first release targets the same NIF `2.16` archive matrix as Parquex: macOS ARM/Intel, Linux GNU ARM/Intel, Linux musl ARM/Intel, and Windows Intel.

## 10. Definition of Initial Success

Roadmap 001 is complete when an Elixir application can embed one supervised Iroh endpoint, persist its own identity, share its public endpoint ID or ticket, establish a mutually authenticated connection over a direct path or a private local relay, and exchange bounded data over concurrent QUIC streams without running an application sidecar.

The proof must include separate local BEAM VMs and forced relay-only traffic, while accurately stating that IrohBeam is an application transport rather than Erlang distribution. The package, documentation, CI, precompiled binaries, checksums, no-Rust consumers, and `0.1.0` release must all be published and verified green.
