# EPIC007 Plan: Documentation, Packaging, and 0.2.0 Release

## Progress

- [ ] Phase 7.1: Freeze public distribution API, configuration, defaults, errors, events, limits, and OTP 29 support.
- [ ] Phase 7.2: Complete and test README, architecture, startup, discovery, security, operations, and troubleshooting docs.
- [ ] Phase 7.3: Complete runnable direct, relay, dynamic, early, and two-machine examples.
- [ ] Phase 7.4: Synchronize `0.2.0` metadata and pass clean docs/package/license/security audits.
- [ ] Phase 7.5: Build and raw-smoke the pinned seven-target NIF release and no-Rust distribution consumers.
- [ ] Phase 7.6: Publish the release, verify exact assets/digests, generate published checksums, commit, and push them.
- [ ] Phase 7.7: Publish/verify Hex and HexDocs, monitor consumers/final CI, and mark the roadmap complete only when green.

## Ordered Implementation

### Phase 7.1 — Contract freeze

1. Review `Distribution.start/1`, `stop/0`, `status/0`, and `peer_info/1` names/results/options.
2. Freeze peer target forms, limits/defaults/units, startup-mode rules, errors, and telemetry events.
3. Verify existing endpoint/connection/stream APIs remain compatible.
4. State OTP `29.x` as the only distribution-carrier runtime and test fail-fast behavior.
5. Remove test hooks/internal structs/resources from public docs and types.

**Exit:** one public contract table matches implementation, tests, and changelog with no unresolved naming/default issue.

### Phase 7.2 — Guides and security model

1. Revise README's transport-only statement to describe the opt-in carrier and retained non-goals.
2. Add architecture/static discovery/no-EPMD and dynamic-versus-early startup guides.
3. Add identity/admission/cookie/relay-token security and credential-rotation guidance.
4. Add lifecycle, ticks, WAN failure, stop/restart, observability, and troubleshooting guidance.
5. Test code/command/config snippets and run docs with warnings as errors.

**Exit:** docs accurately separate identity, reachability, admission, OTP authorization, and membership.

### Phase 7.3 — Executable examples

1. Add a minimal two-local-node direct distribution example.
2. Add custom-relay/forced-relay configuration using fixture placeholders.
3. Demonstrate dynamic startup and correctly staged early boot.
4. Update the two-machine workflow for distinct keys, static mappings, cookies, explicit connect, and inspection.
5. Execute local substitutions in automated tests and ensure cleanup/no credentials.

**Exit:** every supported deployment path has an executable, tested example and every manual-only step is labeled.

### Phase 7.4 — Version and package audit

1. Bump Mix/Cargo/lockfiles/changelog/source refs/install snippets/workflows to `0.2.0`.
2. Update description, support matrix, docs extras, package files, license/notice, and security policy.
3. Build docs with warnings as errors from a clean build.
4. Build/unpack the Hex package and assert required Erlang/native/docs/example files and forbidden test/roadmap/generated files.
5. Run full clean QA and review the source package for sentinel secrets/absolute paths.

**Exit:** local `0.2.0` source package/docs/QA are synchronized and green.

### Phase 7.5 — Precompiled and no-Rust verification

1. Update the pinned seven-target workflow and cache keys for native distribution additions.
2. Build every NIF `2.16` archive and raw-smoke native exports on its target.
3. Validate the exact expected asset names/count before any publication step.
4. In consumers, shadow Cargo/rustc with failing shims and compile the unpacked package.
5. Run existing transport smoke plus two-child-VM no-EPMD connect/ping/RPC/status smoke on supported OTP 29 runners.

**Exit:** all seven archives and no-Rust consumer paths pass before release publication is approved.

### Phase 7.6 — Publish binaries and checksums

1. Commit the green release source state as required, push it, create/push the exact `v0.2.0` tag, and start the pinned release workflow.
2. Monitor every target; cancel doomed remaining jobs when a shared failure is known, then fix/test/commit/push/retag only according to safe release policy.
3. Verify release tag SHA and exactly seven published archives with server-reported SHA-256 digests.
4. Download the published archives, generate the RustlerPrecompiled checksum manifest only from them, and compare all digests.
5. Commit/push the checksum manifest and monitor resulting CI/consumer runs.

**Exit:** published binaries, tag/SHA, server digests, and committed checksums all agree; no local artifact supplied a checksum.

### Phase 7.7 — Package/docs/final verification

1. Publish the Hex package and HexDocs only from the verified release state.
2. Install/compile/run a clean package consumer and verify published docs/version links.
3. Monitor no-Rust consumer matrix and final CI at the checksum commit until all jobs are green.
4. Verify release notes state OTP 29/static discovery/no-membership boundaries and exact artifact set.
5. Mark Epic 7 and ROADMAP002 complete only after all remote evidence is confirmed.

**Exit:** code, tests, docs, package, binaries, checksums, consumers, tag, Hex/HexDocs, and final CI are all verified.

## Test Isolation Checklist

- [ ] Documentation examples use generated fixture credentials and clean every child VM/resource.
- [ ] Package/docs builds run from clean output directories.
- [ ] No-Rust consumers cannot find usable Cargo/rustc and do not reuse source-built native artifacts.
- [ ] Release checksums come only from downloaded published archives.
- [ ] Remote failures block completion and are not hidden by local success.

## Quality Gate

- [ ] Frozen API/config/support and all docs/examples tests pass.
- [ ] Clean full QA, docs warnings-as-errors, package/license/security audits pass at `0.2.0`.
- [ ] Exactly seven archives raw-smoke and publish at the intended tag SHA.
- [ ] Published/server/checksum digests and no-Rust distribution consumers pass.
- [ ] Hex/HexDocs, release notes, tag/assets, consumer CI, and final CI are verified green.

## Commit Rule

Use focused release commits consistent with repository policy. The green release-source epic commit is `roadmap002 - epic 7 - release native iroh distribution 0.2.0` with verification in the body. Checksums are committed only after published assets are downloaded and verified. Never mark Phase 7.6, Phase 7.7, Epic 7, or ROADMAP002 complete based on dispatched but unfinished remote jobs.
