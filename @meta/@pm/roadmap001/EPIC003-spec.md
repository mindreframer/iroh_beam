# EPIC003 Spec: Supervised Endpoints and Network Profiles

## Purpose

Bind embedded Iroh endpoints under OTP supervision with obvious defaults, explicit private-network configuration, and deterministic lifecycle ownership.

## Reference Inputs

- `@meta/@pm/ROADMAP001.md`
- EPIC001 async runtime and EPIC002 identity/dialing values
- Iroh `Endpoint`, builder presets, `RelayMode`, and relay configuration

## Scope

In scope:

- `IrohBeam.Endpoint.start_link/1`, child specification, explicit close, status, ID, address, bound sockets, and online wait
- endpoint ownership by one OTP process and multiple isolated endpoints per VM
- network profiles for `:n0`, minimal/direct, no-relay, and custom relay maps
- validated ALPNs, identity source, bind addresses, relay URLs, auth tokens, startup/shutdown timeouts, and runtime limits
- endpoint address updates needed by `addr/1`
- owner death, application shutdown, supervisor restart, and failed-bind cleanup

Out of scope:

- outgoing/incoming connections and stream I/O
- arbitrary foreign/custom presets, dynamic relay mutation, proxies, custom CA policy, port mapping controls, or every Iroh builder option
- embedded production relay or address-lookup server

## Endpoint Contract

An endpoint is an OTP child, not a global singleton. `start_link/1` validates all options before native bind and returns only after the endpoint is usable under the chosen profile, except where the caller explicitly requests asynchronous online status. Endpoint calls use the EPIC001 operation protocol and never block schedulers.

`:n0` enables Iroh's public relays and DNS/Pkarr lookup. Minimal/direct mode configures no external infrastructure and requires explicit dialing information later. Custom relay mode accepts one or more independently validated relay records with optional bearer tokens. Inspection, errors, logs, and telemetry redact tokens and private keys.

Graceful close has a bounded deadline and waits for native shutdown. Owner death triggers abort cleanup. A restarted child creates a new endpoint resource and retains identity only when the caller configured persistent identity.

## Acceptance Criteria

- Ephemeral and persistent supervised endpoints bind and expose the expected ID/address/sockets.
- Multiple endpoints coexist without shared identity, config, operation, or shutdown state.
- Minimal/direct mode produces no relay, DNS/Pkarr publication, or external-network attempt.
- Custom relay maps and tokens validate before bind and remain redacted.
- Invalid ALPNs, addresses, duplicate identity in one VM, and bind conflicts return stable errors.
- Explicit close, owner kill, failed startup, and supervisor restart release old sockets/tasks within bounded tests.
- Normal endpoint startup/shutdown keeps BEAM schedulers responsive.

## Test Strategy

- Bind loopback endpoints on ephemeral ports with no external service.
- Use deterministic socket conflicts and test-only runtime counters for failure cleanup.
- Start multiple supervised endpoints and kill/restart owners under a test supervisor.
- Capture attempted network destinations to prove minimal mode is infrastructure-free.
- Validate custom relay records without requiring a live relay yet.
- Scan all observable values for identity and token fixtures.

## Quality Bar

- Endpoint resources have one clear OTP owner and deterministic explicit shutdown.
- No profile silently enables external infrastructure contrary to its documented name.
- Easy options are small; advanced records stay typed and validated.
- Endpoint creation does not expose native builder internals.
- Full QA is green before commit.
