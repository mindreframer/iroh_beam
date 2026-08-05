# Changelog

## 0.2.0 — 2026-08-05

- Add an opt-in OTP 29 `iroh_dist` carrier with no EPMD or TCP tunnel.
- Add exact static node-to-Iroh identity discovery and pre-handshake admission.
- Preserve OTP cookies, RPC, links, monitors, ticks, and node lifecycle.
- Add bounded packet-two/four framing, process distribution controllers, iodata writes, and safe counters/telemetry.
- Prove direct and three-VM forced relay-only distribution, layered rejection, relay outage, and explicit recovery.
- Add dynamic and early-boot startup, operational documentation, and two-machine examples.

## 0.1.0 — 2026-08-05

Initial release.

- Embed Iroh 1.0.3 in a Rustler NIF on one managed Tokio runtime.
- Add opaque persistent identities, endpoint IDs, addresses, and standard tickets.
- Add supervised endpoints with n0, direct, no-relay, and custom-relay profiles.
- Add authenticated ID/address/ticket dialing, bounded acceptance, and peer admission.
- Add bounded QUIC streams, datagrams, cancellation, lifecycle cleanup, and telemetry.
- Prove forced private-relay transport between separate local BEAM VMs.
- Ship seven NIF 2.16 precompiled targets and no-Rust consumer verification.
