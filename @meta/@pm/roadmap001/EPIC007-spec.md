# EPIC007 Spec: Hardening, Observability, Packaging, and 0.1.0

## Purpose

Freeze the focused endpoint/connection/stream contract, prove operational safety, and publish an initial precompiled package that consumers can run without Rust.

## Reference Inputs

- `@meta/@pm/ROADMAP001.md`
- EPIC001 through EPIC006 implementation, contracts, tests, and QA gate
- Parquex documentation, package audit, precompiled release, checksum, and no-Rust consumer process
- Hex, ExDoc, RustlerPrecompiled, Iroh, and third-party license requirements

## Scope

In scope:

- final review of public names, defaults, result/error shapes, limits, ownership, cancellation, and compatibility promises
- stable error categories and secret-safe telemetry for endpoint, connect/accept, path, stream, datagram, bytes, duration, queue, and cancellation events
- deterministic fault injection, repeated lifecycle, resource plateau, memory envelope, and scheduler responsiveness tests
- README and guides for identity, direct/private/public profiles, tickets, relays, connections, streams, limits, security, and troubleshooting
- package metadata, changelog, security policy, license/notice attribution, support matrix, docs, and example tests
- pinned CI and seven-target NIF `2.16` release workflow mirroring Parquex
- exact release asset validation, raw smoke tests, checksums from published assets, no-Rust consumers, Hex/docs publication, and final CI monitoring

Out of scope:

- new transport features, higher-level protocols, Erlang distribution, sidecar backend, custom transports, or address-lookup services
- promises of exactly-once delivery, reliable datagrams, automatic reconnection, membership, or relay uptime

## Release and Observability Contract

Errors expose a stable category, operation, human-safe message, and contextual identifiers that are safe to log. Raw upstream debug chains, secret keys, tokens, payload bytes, and peer-provided close reasons are not emitted unsafely. Telemetry has bounded-cardinality metadata; handlers cannot affect correctness.

Memory budgets are functions of configured operation/receive/write/accept limits and Iroh transport windows, not total stream length. Faults terminate within bounded tests and release endpoint, connection, stream, operation, socket, and native-task state.

The release pipeline builds NIF `2.16` archives for macOS ARM/Intel, Linux GNU ARM/Intel, Linux musl ARM/Intel, and Windows Intel. Every archive is smoke-tested before optional publication. The aggregate job validates exactly seven assets and server-reported SHA-256 digests. Checksums are generated only from published assets, then clean consumers compile/load/run with Cargo and rustc replaced by failing shims.

## Acceptance Criteria

- Public contract/errors/telemetry are documented, tested, and contain no unstable native types or secrets.
- All README and guide examples execute in automated tests.
- Fault, repetition, plateau, oversized transfer, cancellation, cleanup, memory, and scheduler tests pass for direct and relay paths.
- Docs/package build with warnings as errors from a clean checkout and package contents are audited.
- Mix/Cargo versions, changelog, docs, metadata, examples, and checksums are synchronized at `0.1.0`.
- Seven target archives are built and smoke-tested; the published release contains exactly those assets at the release commit.
- Clean no-Rust consumers pass on supported consumer targets.
- Hex package, HexDocs, tag, checksums, release assets, consumer CI, and final CI are verified green before completion.

## Test Strategy

- Capture telemetry and all logging/error paths with known secret/payload fixtures and scan output.
- Inject bind/connect/accept/read/write/datagram/relay/close failures at controlled barriers.
- Repeat endpoint/connection/stream lifecycles until tracked resources plateau.
- Transfer data materially larger than configured buffers on direct and forced-relay paths while measuring bounded queues and BEAM responsiveness.
- Run docs examples, package build/unpack audit, raw NIF smoke, and clean consumer smoke.
- Treat every remote release/CI target as a monitored acceptance gate, not a dispatched background task.

## Quality Bar

- No tested panic, scheduler stall, indefinite wait, resource leak, secret disclosure, or unbounded queue remains.
- Documentation accurately distinguishes identity, reachability, relay access, Iroh transport, and Erlang clustering.
- Published binaries and source package retain required licenses and attribution.
- No release completion checkbox is set before remote artifacts, checksums, consumers, Hex/docs, and CI are verified.
- Final QA is green before release commit/tag.
