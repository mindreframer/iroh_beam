# Changelog

## 0.1.0 — 2026-08-05

Initial release.

- Embed Iroh 1.0.3 in a Rustler NIF on one managed Tokio runtime.
- Add opaque persistent identities, endpoint IDs, addresses, and standard tickets.
- Add supervised endpoints with n0, direct, no-relay, and custom-relay profiles.
- Add authenticated ID/address/ticket dialing, bounded acceptance, and peer admission.
- Add bounded QUIC streams, datagrams, cancellation, lifecycle cleanup, and telemetry.
- Prove forced private-relay transport between separate local BEAM VMs.
- Ship seven NIF 2.16 precompiled targets and no-Rust consumer verification.
