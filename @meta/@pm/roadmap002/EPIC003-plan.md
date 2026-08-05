# EPIC003 Plan: Standard OTP Handshake and Direct Node Connectivity

## Progress

- [ ] Phase 3.1: Implement bounded packet-two framing over the distribution stream.
- [ ] Phase 3.2: Implement outgoing `select/1`, `setup/5`, and `handshake_we_started` flow.
- [ ] Phase 3.3: Implement incoming accept handoff, exact allowed names, and `handshake_other_started` flow.
- [ ] Phase 3.4: Bind authenticated endpoint IDs to claimed node names before node-up.
- [ ] Phase 3.5: Prove direct `Node.connect`, node-up/listing, and no-EPMD operation.
- [ ] Phase 3.6: Cover cookie, malformed handshake, cancellation, atom safety, and simultaneous setup failures.
- [ ] Phase 3.7: Pass the epic gate and commit direct native distribution handshake support.

## Ordered Implementation

### Phase 3.1 — Packet-two adapter

1. Add internal async send/receive calls that preserve iodata and stream ownership.
2. Encode/decode two-byte lengths with a 65,535-byte maximum.
3. Implement exact reads over arbitrary QUIC chunk boundaries and retain transition residue.
4. Map EOF/reset/stop/malformed/timeout/cancel outcomes to stable shutdown reasons.
5. Add exhaustive split/coalesce/boundary unit tests and scheduler responsiveness coverage.

**Exit:** every legal frame round-trips; invalid/truncated frames fail within a bound and leak no operation.

### Phase 3.2 — Outgoing handshake

1. Make `select/1` accept only exact normalized peers.
2. Spawn setup with `dist_util:net_ticker_spawn_options/0` and start OTP's setup timer.
3. Resolve/dial/open through the endpoint worker and verify the authenticated ID.
4. Build complete OTP 29 `#hs_data{}` callbacks/address/version/request fields.
5. Call `dist_util:handshake_we_started/1` and make setup death cancel every native phase.

**Exit:** outgoing setup reaches handshake complete against an instrumented valid peer and every staged cancellation returns to baseline.

### Phase 3.3 — Incoming handshake

1. Turn the admitted-stream queue into OTP's linked accept loop and controller handoff protocol.
2. Notify `net_kernel` with the Iroh protocol/family/address record.
3. Build incoming `#hs_data{}` with the exact configured node-name list in `allowed`.
4. Call `dist_util:handshake_other_started/1` only after ownership transfer.
5. Close unsupported protocol, abandoned handoff, and setup-timeout streams deterministically.

**Exit:** configured incoming handshake completes; unknown names are rejected before atom conversion.

### Phase 3.4 — Name/identity binding

1. Carry authenticated endpoint ID in the opaque stream/session state.
2. Resolve the claimed exact node through the immutable ID binding in `f_address`, which OTP calls before `mark_nodeup`.
3. Reject ID/name mismatch and duplicate/ambiguous state with sanitized reasons before `f_address` returns.
4. Add a minimal linked post-handshake holder and `f_getll` PID for this epic only; activation acknowledges and returns without starting data transfer.
5. Instrument test-only phase markers without exposing them publicly.

**Exit:** only the configured node/ID pair can emit node-up, and the holder owns/cleans all resources.

### Phase 3.5 — Direct native node proof

1. Extend child scripts to start two direct Iroh distribution VMs with distinct persistent test identities.
2. Complete `Node.connect/1`; assert exact node lists and node-up observation without sending application distribution traffic.
3. Verify peer IDs and selected paths through safe internal/public status.
4. Assert init arguments include `-proto_dist iroh -no_epmd`.
5. Inspect child state/listeners and EPMD names to prove the nodes start no EPMD child, register no name, and expose no TCP tunnel.

**Exit:** reproducible separate-OS-process node-up works over a direct Iroh path; ping/RPC remain gated on Epic 4.

### Phase 3.6 — Negative handshake matrix

1. Test wrong cookies, unknown endpoint IDs, configured ID/name mismatch, and unconfigured outgoing names.
2. Feed malformed/oversized/truncated packet-two frames at deterministic barriers.
3. Kill setup owner at dial/open/send/receive/complete phases.
4. Trigger simultaneous connects and assert bounded convergence/failure without duplicate resources; full steady-state convergence belongs to Epic 5.
5. Check atom count/known-atom behavior and scan diagnostics for secrets/raw frames.

**Exit:** all negative paths finish within bounds, emit no unauthorized node-up, and return resources to baseline.

### Phase 3.7 — Epic verification

1. Remove any test preface path superseded by the real handshake.
2. Run `bin/qa_check.sh`.
3. Verify all acceptance/non-goal items, especially the temporary holder scope.
4. Review for copied OTP handshake logic, EPMD calls, TCP sockets, and secret leakage.
5. Commit only the green focused diff.

**Exit:** direct handshake support is committed and ready for the process-controller data plane.

## Test Isolation Checklist

- [ ] Main ExUnit VM remains non-distributed; all named-node scenarios run in child OS processes.
- [ ] Every child has a unique node name, identity path, bind address, cookie fixture, and temp root.
- [ ] Negative peers cannot reach public networks or another test's endpoint.
- [ ] Atom-safety tests use existing atoms/strings and do not create the malicious atom themselves.
- [ ] Harness teardown handles linked node processes and native resources after failures.

## Quality Gate

- [ ] Packet-two framing/cancellation/scheduler tests pass.
- [ ] Direct Node connect/node-up/list proof passes without EPMD/TCP.
- [ ] Cookie, ID admission, name binding, malformed frame, and atom safety tests pass.
- [ ] Native operations/resources plateau after repeated handshake failures.
- [ ] Full QA passes.

## Commit Rule

Commit only after full QA as `roadmap002 - epic 3 - connect otp handshakes over iroh`. The body must identify the standard `dist_util` handshake, direct separate-VM node-up proof, cookie/identity failures, no-EPMD evidence, and QA command.
