# EPIC001 Plan: Embedded Native Foundation and Reproducible QA

## Progress

- [x] Phase 1.1: Define public boundaries, non-goals, and embedded-versus-sidecar decision.
- [x] Phase 1.2: Bootstrap the pinned Rustler/Iroh native crate and toolchain.
- [x] Phase 1.3: Implement the managed Tokio runtime and reference-tagged async operation protocol.
- [x] Phase 1.4: Add resource, cancellation, panic-containment, scheduler, and error rules with smoke tests.
- [x] Phase 1.5: Create Parquex-style test foundations and executable `bin/qa_check.sh`.
- [x] Phase 1.6: Add pinned CI and document native architecture and dependency independence.
- [x] Phase 1.7: Pass the epic gate, verify scope, and commit the completed foundation.

## Implementation Steps

1. Replace generated concepts with documented module boundaries and record why the first backend is embedded while a sidecar and Erlang distribution remain deferred.
2. Add the native crate, lockfiles, minimal features, Rust `1.91` toolchain, Rustler loading, and exact crates.io Iroh `1.0.3` pin.
3. Create one managed Tokio runtime and operation registry; submit a deterministic non-network future and reply through an operation reference.
4. Monitor callers, cancel pending work, suppress late replies, register a minimal resource, translate errors, contain panics, and prove scheduler responsiveness.
5. Add isolated fixture/temp helpers, deterministic resource counters/barriers, future test tags, and a fail-fast Elixir/Rust QA script matching Parquex's stage order.
6. Add pinned GitHub CI that fetches locked dependencies and runs only the repository gate; document runtime ownership and verify no local-path Iroh dependency.
7. Run `bin/qa_check.sh`, confirm every criterion and non-goal, review the focused diff, and commit only when green.

## Test Isolation Checklist

- [x] Smoke tests need no sockets, network, credentials, Docker, or sibling checkout.
- [x] Cancellation uses barriers and counters rather than arbitrary sleeps.
- [x] Every native operation reaches one terminal tracked state.
- [x] Test-only native hooks are unavailable in production builds where practical.
- [x] Default tests are order-independent and clean all registered resources.

## Quality Gate

- [x] Embedded load, async completion, error, cancellation, caller-death, and responsiveness tests pass.
- [x] Locked Elixir format/compile/test and Rust format/check/Clippy/test stages pass.
- [x] CI and local QA execute the same logic.
- [x] Diff contains no generated artifacts, secrets, networking behavior, or local absolute dependency.
- [x] Commit title/body follow the roadmap rule.

## Commit Rule

Run `bin/qa_check.sh` from the repository root. Only after it passes and all Epic 1 criteria are complete, commit as `roadmap001 - epic 1 - <native foundation outcome>` with a body summarizing the embedded/runtime decision and verification. Do not commit partial or failing work.
