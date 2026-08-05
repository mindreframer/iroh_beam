# EPIC005 Spec: OTP Semantics, Failure Recovery, and Observability

## Purpose

Prove that the Iroh carrier preserves the OTP distribution behaviors applications depend on, make lifecycle failures deterministic, and expose only safe operational visibility before adding relay complexity.

## Reference Inputs

- `@meta/@pm/ROADMAP002.md`
- EPIC003 handshake/security implementation
- EPIC004 process controller, framing, ticks, and boundedness
- OTP 29 node monitoring, distribution options, simultaneous-connect, and dynamic `net_kernel` behavior
- Existing IrohBeam error/telemetry/redaction conventions

## Scope

In scope:

- links, monitors, exit signals, remote spawn/RPC, registered sends, and node monitoring
- simultaneous connects, duplicate attempts, disconnect, netsplit, and explicit reconnect
- controller/endpoint/peer VM crashes and restart behavior
- wrong cookie, unknown ID, identity/name mismatch, malformed frame, oversized frame, and slow/stalled peer matrix
- dynamic start/stop/restart and early-start limitations
- safe `IrohBeam.Distribution.status/0` and `peer_info/1`
- distribution telemetry/counters, logging policy, and redaction
- repeated lifecycle/resource/atom/mailbox/memory plateau tests
- supported OTP 29 option and node-name-mode behavior documentation

Out of scope:

- automatic reconnect, desired topology, partition healing, membership, or `libcluster`
- guarantees for `global`, `pg`, Mnesia, or application consensus under WAN partitions
- relay-only operation
- public mutation of peer configuration while distribution is running

## OTP Semantics Contract

The carrier must be transparent to OTP once node-up completes. Tests cover:

- bidirectional PID messaging and registered-name messaging;
- links propagating exits according to `trap_exit` behavior;
- process monitors producing `DOWN` with standard remote-process semantics;
- node monitors producing `nodeup`/`nodedown` once per transition;
- RPC success, remote exception, timeout, and large reply;
- simultaneous `Node.connect/1` attempts converging to one live node entry;
- explicit `Node.disconnect/1` closing the Iroh resource graph;
- reconnection only after an application or OTP policy explicitly requests it.

Tests assert semantic outcomes, not unstable internal PIDs, log wording, or timing order beyond OTP's documented guarantees.

## Failure and Recovery Contract

A fatal error in stream input, stream output, QUIC connection, controller, or endpoint must lead to bounded node-down and resource cleanup. Linked/monitored local processes observe normal distribution loss. No carrier process silently restarts an individual link behind OTP.

The dedicated endpoint is part of the distribution supervisor. Dynamic `Distribution.stop/0` uses OTP's supported stop path and waits for resource cleanup. A subsequent `start/1` may use a new immutable configuration only after the prior distribution instance is fully stopped. Early command-line distribution cannot be stopped/reconfigured through the dynamic API where OTP forbids it; this returns an explicit error.

Automatic reconnect is not promised. Tests explicitly issue `Node.connect/1` after the remote VM or local dynamic distribution restarts.

## Observability Contract

`IrohBeam.Distribution.status/0` returns bounded safe fields such as mode, local node, endpoint ID, network profile, readiness, configured peer count, and active link count. `peer_info/1` accepts only a configured node atom and returns expected/authenticated endpoint ID, lifecycle state, selected path kind, and monotonic byte/frame/error counters where available.

Telemetry is emitted only after the telemetry module/application is available; early boot never depends on it. Events cover endpoint readiness, handshake outcome/duration, node up/down, path kind, bytes/frames, queue peaks, cancellation, and rejection category. Metadata is bounded-cardinality and excludes node-controlled free text by default.

Never emit private keys, cookies, relay tokens, ticket text, packet/payload bytes, raw close reasons, arbitrary node-name strings from an unadmitted peer, or native debug chains.

## Acceptance Criteria

- Standard RPC, messaging, registered sends, links, process monitors, node monitors, exits, and disconnect behavior pass between separate direct-mode VMs.
- Simultaneous reciprocal connects converge to one node entry and one live controller/resource set on each side.
- VM kill, endpoint loss, stream reset, controller/input/output death, malformed/oversized frame, and stalled peer each produce bounded node-down/cleanup.
- Explicit reconnect after peer restart succeeds with a new distribution incarnation and no stale controller.
- Dynamic start/stop/start works; duplicate start and forbidden early stop/reconfigure return clear errors.
- Repeated success/failure/reconnect cycles plateau in atom count, native resources, controller processes, mailboxes, sockets, and measured memory.
- Status, peer info, telemetry, errors, and captured logs are bounded, accurate, and secret/payload safe.
- Existing general Iroh transport observability remains compatible.
- Full QA passes.

## Test Strategy

- A scenario matrix in the separate-process harness, with bounded commands and explicit semantic assertions inside child VMs.
- Deterministic barriers for controller/input/output death and malformed native peer injection.
- Simultaneous-connect synchronization instead of sleeps.
- Peer kill/restart with node incarnation and monitor assertions.
- Dynamic distribution restart in fresh child VMs so the main test VM remains unaffected.
- Lifecycle loops with warm-up and before/after snapshots for atoms, processes, mailboxes, native resources, sockets, and memory.
- Capture telemetry/logs using known sentinel secrets/payloads and scan all output/package diagnostics.
- Verify early telemetry absence and later handler attach/detach safety.

## Quality Bar

- The carrier does not claim stronger delivery or healing semantics than OTP distribution provides.
- Failure tests use finite deadlines and classify expected node-down versus test harness failure.
- No recovery path creates a second endpoint/controller for one active distribution instance.
- Telemetry handler failures cannot affect carrier correctness.
- Public status uses stable Elixir values and contains no raw Rust resources or OTP distribution handles.
