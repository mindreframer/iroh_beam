# EPIC001 Plan: OTP 29 Carrier Foundation and Compatibility Gate

## Progress

- [x] Phase 1.1: Record the carrier, OTP-semantics, EPMD, discovery, and compatibility decisions.
- [x] Phase 1.2: Add Erlang source compilation/package support and the centralized OTP 29 guard.
- [x] Phase 1.3: Implement the complete `iroh_dist` callback skeleton and inert early child spec.
- [x] Phase 1.4: Add callback, address, creation, boot-order, and unsupported-runtime tests.
- [x] Phase 1.5: Build the bounded separate-OS-process distribution test harness.
- [x] Phase 1.6: Extend QA and pinned CI for Erlang carrier sources and process cleanup.
- [x] Phase 1.7: Pass the epic gate, verify no live transport scope, and commit the foundation.

## Ordered Implementation

### Phase 1.1 — Architecture contract

1. Add an ADR that selects a direct alternative carrier and OTP 29 process controllers.
2. State that OTP owns handshakes, cookies, terms, links, monitors, ticks, and lifecycle semantics.
3. State that static discovery is independent from transport and that `-no_epmd` is the supported mode.
4. Reject TCP tunneling, a custom EPMD module, a sidecar, and broad OTP compatibility for this release.
5. Document the early-worker boot constraint and why critical modules are Erlang/internal.

**Exit:** ADR and module responsibility table agree with ROADMAP002 and contain no implementation claim not covered by a later epic.

### Phase 1.2 — Build and runtime guard

1. Configure Mix to compile the minimal Erlang source directory without changing public application startup.
2. Add one internal support module that parses the running OTP release and enforces major 29.
3. Make the guard injectable/pure enough to test unsupported release strings.
4. Include Erlang inputs required by source builds in package metadata.
5. Add formatter/compiler settings so Erlang warnings fail QA.

**Exit:** supported and unsupported guard tests pass; unpacked package contains every source/header input needed by a clean consumer.

### Phase 1.3 — Carrier callback skeleton

1. Add `iroh_dist` with all required OTP 29 callback exports and specs/comments linking each callback to its owner.
2. Return an Iroh `#net_address{}` and fresh valid creation without consulting EPMD.
3. Add one inert early-worker child spec with deterministic start/stop and no native bind.
4. Make `select/1` reject unresolved nodes and make live callbacks return bounded not-ready errors.
5. Ensure `close/1` and worker termination are idempotent.

**Exit:** OTP can load and invoke every callback; no path opens a network resource or blocks.

### Phase 1.4 — Contract and boot probes

1. Assert callback exports/arities and address-record fields.
2. Test creation range and non-reuse across a statistically meaningful bounded sample without flaky uniqueness assumptions.
3. Probe protocol loading with `-proto_dist iroh -no_epmd`.
4. Probe early named startup through the intentional not-ready error and verify bounded exit.
5. Verify no EPMD registration, TCP listener, Iroh resource, or telemetry call occurs.

**Exit:** all callback and boot probes fail only at the documented inert boundary.

### Phase 1.5 — Separate-process harness

1. Add a test helper that starts child `elixir`/`erl` OS processes with explicit argv and environment.
2. Use unique temp roots and a line-delimited stdio/file control protocol independent of Erlang distribution.
3. Add bounded readiness, command, completion, and shutdown timeouts.
4. Capture bounded stdout/stderr and child exit status for diagnostics.
5. Kill the process tree and delete temporary identities/configuration on every exit path.

**Exit:** harness self-tests cover ready, error, timeout, forced kill, and cleanup with no orphan process.

### Phase 1.6 — Authoritative gate

1. Add Erlang compile/test/package checks to `bin/qa_check.sh` in a deterministic stage.
2. Add explicit OTP-major reporting/assertion.
3. Run harness self-tests in CI without Docker.
4. Keep CI as a pinned wrapper around the repository gate.
5. Preserve all existing Rust, direct, relay, docs, and package checks.

**Exit:** local and CI paths execute the same new checks and existing ROADMAP001 tests remain green.

### Phase 1.7 — Epic verification

1. Run `bin/qa_check.sh` from the repository root.
2. Review every acceptance criterion and non-goal against test evidence.
3. Confirm the diff has no live Iroh distribution bind/dial, copied OTP code, credentials, or unrelated cleanup.
4. Check only completed phase/checklist items.
5. Commit the green epic.

**Exit:** clean working tree after commit and reproducible green QA.

## Test Isolation Checklist

- [x] Foundation tests require no Docker, relay, DNS, public network, EPMD, or sibling Iroh checkout.
- [x] Child VMs use unique names/temp roots and bounded output.
- [x] Harness cleanup runs on success, failure, timeout, and test-process exit.
- [x] Version tests do not require installing an unsupported OTP.
- [x] No test mutates global distribution state in the main ExUnit VM.

## Quality Gate

- [x] ADR and callback ownership are unambiguous.
- [x] OTP 29 guard, Erlang compile, exports, records, creations, and boot probes pass.
- [x] Package audit includes required Erlang inputs.
- [x] Process harness leaves no child VM or temporary credential.
- [x] Full `bin/qa_check.sh` passes and no live distribution transport exists yet.

## Commit Rule

Commit only after the full gate passes as `roadmap002 - epic 1 - establish otp29 carrier foundation`. The body must state the direct-carrier/OTP-semantics decision, OTP 29 support boundary, harness result, and exact QA command.
