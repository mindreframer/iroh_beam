# EPIC005 Plan: OTP Semantics, Failure Recovery, and Observability

## Progress

- [ ] Phase 5.1: Prove standard messaging, RPC, link, monitor, exit, and node-monitor semantics.
- [ ] Phase 5.2: Make simultaneous connect, disconnect, duplicate attempt, and controller ownership deterministic.
- [ ] Phase 5.3: Implement bounded failure propagation for stream, connection, controller, endpoint, and malformed-peer faults.
- [ ] Phase 5.4: Implement explicit dynamic stop/restart and peer reconnect behavior.
- [ ] Phase 5.5: Add safe distribution status, peer information, counters, telemetry, and logging policy.
- [ ] Phase 5.6: Run security, redaction, atom/resource/mailbox/memory plateau, and scheduler hardening.
- [ ] Phase 5.7: Pass the epic gate and commit the hardened direct distribution carrier.

## Ordered Implementation

### Phase 5.1 — OTP behavior matrix

1. Extend child commands for bidirectional PID and registered-name messages.
2. Test RPC success, exception, timeout, and large reply.
3. Test links with normal/abnormal exits and `trap_exit` on/off.
4. Test process monitors and node monitors across normal peer/process exits.
5. Test explicit disconnect and assert standard node-list/node-down outcomes.

**Exit:** semantic tests pass without carrier-specific application code after node-up.

### Phase 5.2 — Connection races

1. Synchronize reciprocal `Node.connect/1` calls at a barrier.
2. Exercise repeated duplicate connect calls before, during, and after node-up.
3. Let OTP's handshake statuses select the surviving link; do not invent a second arbitration protocol.
4. Close the losing Iroh stream/connection/controller immediately and idempotently.
5. Assert one node table entry and one live resource/controller set per peer.

**Exit:** race tests converge deterministically and losing resources return to baseline.

### Phase 5.3 — Fault propagation

1. Inject stream EOF/reset, QUIC close, input death, output death, controller death, and endpoint abort.
2. Inject malformed/oversized packet-four data and stalled read/write conditions.
3. Ensure each fatal fault closes both stream halves and the QUIC connection once.
4. Assert bounded `nodedown`, link exit, process `DOWN`, and waiting-call release.
5. Normalize/log only safe failure categories.

**Exit:** every fault has one terminal lifecycle and no hung process/resource.

### Phase 5.4 — Stop and recovery

1. Implement dynamic `Distribution.stop/0` through OTP's supported distribution stop function.
2. Wait for endpoint/controller/native cleanup before allowing a new start.
3. Reject duplicate start, stop-during-start, reconfigure-while-running, and forbidden early-mode stop clearly.
4. Restart remote child VMs and explicitly reconnect, checking new incarnation and no stale node state.
5. Test local dynamic stop/start with the same and a changed valid immutable configuration.

**Exit:** supported stop/start/reconnect scenarios pass and unsupported transitions fail without partial state.

### Phase 5.5 — Safe operations visibility

1. Implement bounded `status/0` and exact-configured-node `peer_info/1`.
2. Add monotonic counters and path/lifecycle snapshots without retaining payloads or peer prose.
3. Emit documented telemetry only when telemetry is available after boot.
4. Pair start/stop or start/exception events and bound metadata cardinality.
5. Document units, event names, path meaning, and unsupported fields.

**Exit:** status/telemetry tests are stable, handler-safe, and accurate under success/failure.

### Phase 5.6 — Hardening and plateaus

1. Repeat connect/traffic/disconnect, wrong-cookie, unknown-ID, malformed-frame, and reconnect cycles.
2. Snapshot atom count, process/controller count, mailbox peaks, sockets, native resources, and memory after warm-up.
3. Assert plateaus/envelopes with documented tolerances and scheduler probes.
4. Scan logs/errors/events/status for sentinel key, cookie, token, ticket, packet, and payload values.
5. Verify no remote name becomes an atom before exact configured-name approval.

**Exit:** lifecycle/security measurements plateau and all observable channels pass redaction.

### Phase 5.7 — Epic verification

1. Run full `bin/qa_check.sh`.
2. Review semantics against OTP documentation and remove carrier-specific overclaims.
3. Verify dynamic/early lifecycle boundaries and all failure deadlines.
4. Inspect diff for dynamic membership, automatic reconnect, relay scope, or unrelated cleanup.
5. Commit the focused green carrier.

**Exit:** hardened direct carrier with safe visibility is committed.

## Test Isolation Checklist

- [ ] Semantic scenarios run in disposable child VMs and never distribute the ExUnit VM.
- [ ] Connect races use barriers and unique nodes, not arbitrary sleeps.
- [ ] Fault hooks are test-only and inaccessible in packaged production paths where practical.
- [ ] Telemetry handlers detach and global application environment is restored.
- [ ] Plateau loops have fixed iteration/time bounds and always kill child process trees.

## Quality Gate

- [ ] RPC/messaging/link/monitor/exit/node-monitor semantics pass.
- [ ] Simultaneous connect and duplicate attempts leave one live link.
- [ ] Fault, stop/start, peer restart, and explicit reconnect tests pass.
- [ ] Status/telemetry accuracy and full redaction pass.
- [ ] Atom/resource/mailbox/socket/memory/scheduler bounds pass and full QA is green.

## Commit Rule

Commit only after full QA as `roadmap002 - epic 5 - harden otp semantics and recovery`. The body must state semantic coverage, simultaneous-connect result, fault/reconnect evidence, plateau/redaction measurements, and QA command.
