# EPIC001 Spec: Embedded Native Foundation and Reproducible QA

## Purpose

Prove that current Iroh can run safely as an embedded Rustler NIF, establish one asynchronous native-operation protocol, and create the repository quality process before endpoint behavior is added.

## Reference Inputs

- `@meta/@pm/ROADMAP001.md`
- Parquex QA, CI, Rustler, precompiled-release, and test-support structure
- Local Iroh `1.0.3` source and official `iroh-ffi` runtime/resource patterns

## Scope

In scope:

- initial `IrohBeam`, native, error, endpoint, connection, stream, identity, relay, and telemetry module boundaries
- native crate with crates.io dependencies pinned to Iroh `1.0.3`, Rustler, and Rust `1.91`
- one managed Tokio runtime and a non-network asynchronous smoke operation
- reference-tagged completion messages, caller monitoring, cancellation, and late-result suppression
- Rustler resource registration, panic containment, stable error translation, and scheduler rules
- executable `bin/qa_check.sh`, pinned GitHub CI, fixture/temp/leak helpers, and test tags
- ADRs for embedded NIF versus sidecar, async runtime ownership, and initial stable-Iroh scope

Out of scope:

- secret-key generation, endpoints, sockets, DNS, relays, connections, streams, or datagrams
- Iroh higher-level protocols or Erlang distribution
- production precompiled publication

## Native Boundary Contract

NIF entry points perform validation and bounded state manipulation only. They never wait on network futures or call `Runtime::block_on` while occupying a BEAM scheduler. Long work is submitted to the managed Tokio runtime and replies exactly once as `{IrohBeam.Native, operation_ref, result}` to the requesting process. A monitor/cancellation token ties each operation to the caller; explicit cancellation and caller death prevent useful work and suppress late delivery.

Rust panics are contained at recoverable boundaries and become stable internal errors. Resource destructors cannot block. Explicit asynchronous shutdown is the deterministic path; drop is a final abort safety net. The project depends on crates.io and must build without the sibling Iroh checkout.

## Acceptance Criteria

- The embedded NIF loads and reports pinned runtime/upstream versions.
- A public smoke operation completes asynchronously through the reference protocol.
- Cancelling that operation and killing its caller leave no tracked native operation.
- A translated native failure reaches Elixir without panic details or VM instability.
- A responsiveness test proves the smoke operation does not occupy a normal BEAM scheduler.
- `bin/qa_check.sh` performs deterministic locked Elixir and Rust checks and passes from the repository root.
- CI invokes the same gate with pinned actions/toolchains.
- No networking behavior is introduced.

## Test Strategy

- Test native load, success, translated failure, duplicate/late completion suppression, explicit cancellation, and caller death.
- Expose test-only deterministic counters/barriers rather than relying on sleeps.
- Run a BEAM responsiveness probe while native async work is pending.
- Check the native dependency graph and package paths for sibling-checkout references.
- Keep future relay, multi-BEAM, and release tests tagged and excluded until their owning epics.

## Quality Bar

- No `unwrap`/`expect` or panic path is reachable from untrusted NIF input.
- No native future waits on a normal BEAM scheduler.
- Native global state is limited to the managed runtime and test-safe operation registry.
- Errors are stable and contextual; debug internals remain native logs at controlled levels.
- `bin/qa_check.sh` is authoritative and green before commit.
