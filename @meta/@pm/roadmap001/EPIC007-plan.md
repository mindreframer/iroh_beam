# EPIC007 Plan: Hardening, Observability, Packaging, and 0.1.0

## Progress

- [ ] Phase 7.1: Stabilize public API, defaults, limits, ownership, cancellation, and error categories.
- [ ] Phase 7.2: Add bounded-cardinality secret-safe telemetry and observability tests.
- [ ] Phase 7.3: Add fault injection, repeated lifecycle, resource plateau, memory, and scheduler hardening.
- [ ] Phase 7.4: Complete runnable documentation, examples, security guidance, licenses, and package metadata.
- [ ] Phase 7.5: Add and validate the pinned seven-target precompiled NIF and no-Rust consumer pipelines.
- [ ] Phase 7.6: Synchronize `0.1.0`, pass clean QA/docs/package audits, publish, verify artifacts, and commit checksums.
- [ ] Phase 7.7: Verify Hex/HexDocs, no-Rust consumers, release tag/assets/digests, and final CI before marking the roadmap complete.

## Implementation Steps

1. Review and freeze names, options, defaults, return values, errors, byte limits, owner/caller semantics, close behavior, and compatibility statements without expanding scope.
2. Emit documented telemetry at endpoint, connection, path, stream, datagram, byte, duration, queue, and cancellation boundaries; test cardinality, units, pairing, and redaction.
3. Inject every major fault path, repeat lifecycles to a plateau, enforce direct/relay memory envelopes, and prove scheduler responsiveness and bounded cleanup.
4. Write and test README/guides/examples; complete security, troubleshooting, support matrix, license/notices, changelog, ExDoc, and package-content configuration.
5. Mirror Parquex's pinned CI/release jobs, package scripts, seven NIF `2.16` targets, exact asset validation, raw smoke tests, and no-Rust consumer matrix.
6. Synchronize Mix/Cargo/lockfiles/docs/examples at `0.1.0`; run clean QA/docs/package audits; commit the green release state, publish and monitor assets; generate checksums only from published archives and commit/push them.
7. Monitor final CI and consumers, verify exact tag/SHA/assets/server digests/checksum manifest, publish Hex and docs, and only then mark all release and roadmap completion boxes.

## Test Isolation Checklist

- [ ] Faults use hooks/barriers rather than public-network instability or arbitrary sleeps.
- [ ] Telemetry handlers detach and captured output contains no secrets or payloads.
- [ ] Memory tests document configuration, warm-up, measurement boundary, and tolerance.
- [ ] Clean package/consumer checks ignore cached native artifacts and cannot invoke Rust.
- [ ] Release checksums come from downloaded published assets, never local build outputs.

## Quality Gate

- [ ] API, error, telemetry, fault, plateau, memory, scheduler, cleanup, and redaction reviews pass.
- [ ] Every documented example and direct/private-relay workflow test passes.
- [ ] Clean `bin/qa_check.sh`, docs warnings-as-errors, and package audit pass.
- [ ] Exactly seven archives pass raw smoke and publication asset validation.
- [ ] Published checksums, no-Rust consumers, Hex/HexDocs, tag/SHA, and final CI are verified green.
- [ ] Diff contains no credentials, generated junk, stale roadmap claims, or deferred features.
- [ ] Commit title/body follow the roadmap rule.

## Commit Rule

Run `bin/qa_check.sh` from a clean checkout before the release commit. Commit the green release as `roadmap001 - epic 7 - <hardening and 0.1.0 outcome>` with an informative verification body. Publish and monitor the precompiled release; generate and commit checksums only from published assets. Do not mark Epic 7 or ROADMAP001 complete until package/docs, tag, exact binaries, digests, consumers, and final CI are all verified.
