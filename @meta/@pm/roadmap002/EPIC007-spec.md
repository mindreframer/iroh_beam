# EPIC007 Spec: Documentation, Packaging, and 0.2.0 Release

## Purpose

Freeze the optional Erlang distribution carrier, document its exact support/security/operational boundaries, and publish IrohBeam `0.2.0` with verified precompiled binaries and no-Rust OTP 29 consumers.

## Reference Inputs

- `@meta/@pm/ROADMAP002.md`
- EPIC001–EPIC006 implementation, tests, measurements, and decisions
- Existing ROADMAP001 package, docs, CI, release, checksum, and no-Rust consumer process
- OTP 29 alternative distribution/process-controller documentation
- Hex, ExDoc, RustlerPrecompiled, Iroh, and third-party license requirements

## Scope

In scope:

- final review/freeze of `IrohBeam.Distribution`, configuration, errors, defaults, limits, events, and compatibility promises
- README correction from transport-only wording to optional distribution support
- guides for architecture, static discovery, dynamic startup, early boot, direct use, private relay, security, operations, troubleshooting, and migration
- runnable direct and relay examples
- OTP `29.x`/Elixir `~> 1.20` support metadata and fail-fast behavior
- package audit for Erlang sources and distribution docs/examples
- synchronized Mix/Cargo/lockfile/changelog/docs/examples/checksum metadata at `0.2.0`
- refreshed seven-target NIF `2.16` precompiled release
- raw archive smoke and no-Rust consumer tests that start two Iroh distribution VMs on OTP 29
- published checksums, Hex/HexDocs, release/tag/SHA/digest verification, and final CI monitoring

Out of scope:

- adding new discovery, membership, transport, controller, tuning, or compatibility features during release hardening
- OTP versions other than 29
- production relay hosting automation or guarantees

## Documentation Contract

Documentation must distinguish five concepts consistently:

1. **Identity:** each VM has a distinct Iroh private key and public endpoint ID.
2. **Reachability:** ID/address/ticket plus direct/public/private-relay network profile lets Iroh dial.
3. **Admission:** exact configured node-to-endpoint-ID bindings decide who reaches/finishes the OTP handshake.
4. **OTP authorization:** Erlang cookies and the standard handshake remain active.
5. **Membership:** application code decides which configured nodes to connect and maintain.

Required operational guidance includes:

- launch argv for dynamic and early named startup;
- why dynamic startup must still receive `-proto_dist iroh -no_epmd` before VM boot;
- why early configuration must be in boot-time application environment and may precede late runtime providers;
- exact peer map examples using ID, address, and ticket targets;
- persistent identity and cookie distribution practices;
- no-EPMD verification;
- relay token versus cookie versus endpoint allowlist troubleshooting;
- ticks and WAN failure expectations;
- stopping/restarting dynamic distribution and limitations of early mode;
- static configuration rotation requiring a distribution restart;
- explicit non-goals: membership, auto-connect, partition healing, dynamic discovery, and broad OTP compatibility.

## Release Contract

The version is `0.2.0` in Mix, Cargo, lockfiles, docs, examples, changelog, source refs, and release workflows. The changelog calls out the new optional carrier and the OTP 29 support requirement without implying that general transport APIs require named distribution.

The existing seven NIF `2.16` target archives are rebuilt because the native crate changes. Every archive is raw-smoke tested before publication. The aggregate release job validates exactly the expected assets and server-reported SHA-256 digests. Checksums are generated only by downloading published release assets, then committed and pushed.

At least supported native consumer runners compile the unpacked Hex package with `cargo` and `rustc` replaced by failing shims, load the precompiled NIF, and run:

- existing general transport smoke;
- distribution configuration/status smoke;
- a two-child-VM direct `Node.connect`/ping/RPC smoke on OTP 29 without EPMD.

Remote release, consumer, package, docs, and CI jobs are monitored to completion. A dispatched workflow is not acceptance evidence.

## Acceptance Criteria

- Public API/config/errors/events/defaults/limits are frozen, documented, and match tests.
- README and all guides accurately present optional distribution while preserving general transport behavior.
- Dynamic, early, direct, relay, security, failure, and troubleshooting examples execute in automated/local substitution tests.
- Package builds/docs compile with warnings as errors and include required Erlang carrier inputs/docs/examples but exclude tests, roadmap files, secrets, and generated junk.
- OTP 29 support and unsupported-version behavior are explicit in metadata/docs/tests.
- Mix/Cargo/locks/changelog/docs/examples/workflows are synchronized at `0.2.0`.
- Exactly seven target archives build, raw-smoke, publish at the release commit, and match server SHA-256 digests.
- Published checksum manifest is generated from those downloaded assets and clean no-Rust consumers pass general and distribution smoke.
- Hex package, HexDocs, tag, release assets, checksums, consumer CI, and final CI are verified green before roadmap completion.

## Test Strategy

- Convert every documented command/config/API sample into a tested fixture or local substitution.
- Build/unpack Hex package in a clean directory and assert exact critical include/exclude paths.
- Run docs with warnings as errors and link/reference checks.
- Run unsupported OTP guard tests without claiming an unsupported consumer matrix.
- Raw-smoke each archive in release workflow before upload.
- Verify exact release asset names/counts/digests and tag commit.
- Run no-Rust consumers with Rust executables shadowed by failing scripts.
- Download published artifacts for checksums; compare manifest and server digests.
- Monitor final CI/consumer jobs and record URLs/SHAs in the release verification notes where repository practice permits.

## Quality Bar

- No release document weakens the static admission, distinct identity, cookie, no-EPMD, boundedness, or OTP 29 contracts.
- No sample embeds a real secret key, cookie, relay token, or reusable credential.
- Licenses/notices remain correct for all source and precompiled contents.
- Release work contains no opportunistic transport feature.
- No phase or roadmap completion box is checked before corresponding remote evidence exists.
