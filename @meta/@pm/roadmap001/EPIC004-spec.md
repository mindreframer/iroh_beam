# EPIC004 Spec: Authenticated Connections and Admission

## Purpose

Let Elixir processes dial and accept mutually authenticated Iroh/QUIC connections by key-derived identity while keeping discovery requirements and admission policy explicit.

## Reference Inputs

- `@meta/@pm/ROADMAP001.md`
- EPIC002 dialing values and EPIC003 supervised endpoints
- Iroh endpoint connect/accept, ALPN, connection, and path APIs

## Scope

In scope:

- `Endpoint.connect/4` using an `EndpointId`, `EndpointAddr`, or `EndpointTicket`
- documented ID-only resolution behavior under each network profile
- pull-based `Endpoint.accept/2` returning completed authenticated connections
- ALPN negotiation, remote endpoint ID, side, stable connection ID, selected-path snapshot/RTT, close, close reason, and closed wait
- optional endpoint peer allowlist enforced on authenticated remote IDs
- bounded accept/connect queues and operation timeouts
- refusal, endpoint/connection close, caller death, owner death, and malformed/unsupported peer behavior

Out of scope:

- application framing, RPC, protocol handler behavior, router callbacks, service discovery, membership, or reconnection policy
- pre-handshake IP screening, retry-token policy, 0-RTT, multipath event streams, or all connection tuning controls
- Erlang distribution or implicit BEAM process messaging

## Connection Contract

Dial targets retain their semantics. An endpoint ID alone works only when configured address lookup can resolve it or when Iroh already has usable cached information. Minimal/custom deployments normally share an endpoint ticket or explicit address unless the application supplies another lookup mechanism. Failures identify missing dialing information rather than falling back to public infrastructure.

`accept/2` is demand-driven. The endpoint owns the native accept loop and holds only a bounded queue; callers may run any OTP accept-loop pattern they choose. Returned connections expose the cryptographically authenticated remote endpoint ID and negotiated ALPN. An optional allowlist is checked immediately after authentication; rejected peers never become successful application accepts.

Connection timeout/cancellation is operation-scoped. Connection close interrupts its stream operations but not unrelated connections or the endpoint. Handles are explicitly closeable and resource-drop safe.

## Acceptance Criteria

- Two local endpoints connect directly through an explicit endpoint address and observe matching remote IDs, ALPN, sides, and a direct path.
- ID-only dialing succeeds with a deterministic configured lookup fixture and returns a clear resolution error without lookup/address data.
- Address and ticket dialing do not require public infrastructure.
- Unsupported ALPN, malformed target, closed endpoint, timeout, and refused connection return stable categories.
- An authenticated but unlisted peer is rejected before successful `accept/2` delivery.
- Queue limits prevent unbounded incoming/pending connection growth.
- Caller/owner death and cancellation remove handshakes, accepts, and connection resources without affecting unrelated work.

## Test Strategy

- Use two or more loopback endpoints with relays disabled and explicit addresses.
- Add a deterministic in-memory lookup fixture only for ID-resolution contract tests.
- Cover ALPN mismatch, allow/deny identities, queue saturation, timeout, close races, repeated connect/close, and malformed values.
- Assert path kind rather than machine-specific socket ordering or RTT.
- Use barriers/native counters for pending handshake and cancellation tests.

## Quality Bar

- Authentication is always derived from Iroh endpoint identity; no wrapper-level unauthenticated connection exists.
- The wrapper never silently enables a public lookup or relay.
- Incoming work is bounded and demand/ownership semantics are documented.
- Connection resources and errors do not expose private keys, auth tokens, or unstable Rust types.
- Full QA is green before commit.
