# ADR 0003: Stable Iroh 1.0 scope

## Status

Accepted for ROADMAP001.

## Decision

The native crate pins the crates.io `iroh` package exactly to `1.0.3` and Rust
to `1.91.0`. The sibling Iroh checkout is research material only and is not a
build input.

The first release is limited to endpoint identity/address/tickets, endpoint
lifecycle, stable authenticated connections, selected path information, QUIC
streams and datagrams, and explicit relay profiles. Higher-level Iroh protocols,
unstable transports and network-report APIs, Erlang distribution, sidecars,
application protocols, and production relay orchestration are deferred.

This keeps one public Elixir model while preserving room for later opt-in
features without exposing the complete upstream builder API.
