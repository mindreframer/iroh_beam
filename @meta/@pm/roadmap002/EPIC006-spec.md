# EPIC006 Spec: Forced Relay-Only Multi-BEAM Cluster Proof

## Purpose

Prove the roadmap's network goal with three distinct BEAM VMs communicating through the pinned private Iroh relay while direct IP transport is disabled, and make clear that the carrier supplies connectivity while applications still choose cluster membership/topology.

## Reference Inputs

- `@meta/@pm/ROADMAP002.md`
- EPIC005 hardened direct carrier and child-process harness
- ROADMAP001 pinned relay, Docker Compose, token, readiness, and relay-only test infrastructure
- Existing two-machine transport example and private-relay documentation

## Scope

In scope:

- three separate OS processes/OTP 29 VMs with distinct persistent Iroh identities
- reciprocal exact static peer configuration
- custom private relay profile with direct IP disabled
- explicit application/test-issued `Node.connect/1` topology formation
- relay-path verification for every live link
- ping, RPC, messages, links, monitors, large concurrent traffic, ticks, disconnect, and reconnect over relay
- wrong relay token, wrong cookie, unknown endpoint ID, and identity/name mismatch relay cases
- relay outage diagnostics and bounded recovery after relay/peers are restored
- QA-owned relay startup/readiness/logging/teardown and manual two-machine distribution example

Out of scope:

- claiming the local relay simulates arbitrary NATs, firewalls, physical machines, latency, or packet loss
- automatic membership, topology convergence, WAN partition healing, or relay high availability
- production relay deployment automation
- requiring an existing QUIC link to survive every relay process restart

## Three-VM Proof

The integration scenario starts nodes `a`, `b`, and `c` (unique names per run), each with:

- its own Iroh secret key and endpoint ID;
- the fixed distribution ALPN;
- `network: {:custom, [local_relay]}` and `direct_ip: false`;
- exact static entries for the other two node names/IDs/relay addresses;
- one shared Erlang cookie for the success case;
- no EPMD child or registration attributable to these nodes and no TCP distribution listener.

The harness, not an automatic membership component, commands explicit connects. It forms at least a full three-node connected topology and verifies each node's `Node.list/0`. Every active peer status must report `:relay`; any direct/IP path is a test failure.

Each node remains an independent OS process. `dev_cluster` may help launch processes only if it does not bootstrap or carry the distribution under test; the non-distributed harness remains the source of truth.

## Relay Failure Contract

Tests distinguish:

- relay admission failure caused by a wrong token;
- endpoint/OTP admission failure caused by unknown ID or wrong cookie;
- active link failure after relay shutdown;
- inability to establish a new link while the only relay path is unavailable;
- successful explicit reconnection after relay readiness and required peer restart/rebind.

The carrier is not required to keep an existing relayed QUIC connection alive through relay process loss. The accepted outcome is bounded node-down followed by explicit recovery. If Iroh preserves an active path in a tested case, the test may accept it but must still prove that new connections fail while no route exists.

## Physical-Network Example

A runnable example documents two machines/networks:

1. generate distinct identities;
2. obtain endpoint IDs/tickets without sharing private keys;
3. configure exact Erlang node mappings and the same cookie out of band;
4. launch with `-proto_dist iroh -no_epmd` using dynamic or correctly staged early config;
5. call `Node.connect/1` explicitly;
6. inspect authenticated ID/path and test ping/RPC;
7. troubleshoot relay token, cookie, discovery, identity binding, and tick failures.

The example must not contain production credentials or assert success solely from local tests.

## Acceptance Criteria

- Three separate VMs form the commanded Erlang topology through the local relay with direct IP disabled.
- Every link reports a relay path and no EPMD/TCP carrier exists.
- Ping, exact node lists, RPC, messaging, links, monitors, large concurrent traffic, and multiple idle tick intervals pass over relay.
- Wrong relay token fails before endpoint connection; unknown ID fails before handshake; wrong cookie fails in OTP handshake; identity/name mismatch emits no node-up.
- Relay shutdown produces bounded diagnosable outcomes; new links fail while unavailable; explicit recovery works after readiness and any required peer restart.
- QA starts/reuses the pinned relay, waits within a bound, prints container/status/log diagnostics on failure, and provides explicit teardown.
- Relay scenarios leave no child VM, container created solely by the test, temporary identity, connection, controller, or native operation.
- The manual two-machine example and docs are executable/tested where local substitution is possible and accurately state test limitations.
- Full QA passes.

## Test Strategy

- One full three-VM scenario to reduce repeated container cost, with isolated sub-scenarios or fresh peers where security state could contaminate results.
- Parent-child stdio/file control only; no hidden distributed control node.
- Path assertions from both Iroh connection metadata and disabled-direct configuration.
- Deterministic payload hashes, sequence accounting, and tick windows with generous CI bounds.
- Relay token/cookie/ID sentinels scanned from child logs, Docker logs exposed by QA, telemetry, and errors.
- Relay stop/readiness restart controlled by Docker Compose with failure diagnostics.
- Process/container/native snapshots before and after scenario teardown.

## Quality Bar

- Relay tests never silently fall back to public n0 infrastructure or direct IP.
- All image/action/tool inputs stay pinned according to repository release policy.
- Test failures identify relay readiness, child readiness, handshake, route, data, tick, or cleanup stage.
- Shared relay token and cookie are fixture-only and never logged.
- Documentation separates transport reachability, static discovery, endpoint admission, cookie authorization, and membership.
