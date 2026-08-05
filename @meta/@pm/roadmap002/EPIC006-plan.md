# EPIC006 Plan: Forced Relay-Only Multi-BEAM Cluster Proof

## Progress

- [x] Phase 6.1: Extend the harness for three relay-only distribution VMs and exact peer fixtures.
- [x] Phase 6.2: Prove explicit three-node topology formation and relay path enforcement.
- [x] Phase 6.3: Prove OTP semantics, large concurrent traffic, and idle ticks over relay.
- [x] Phase 6.4: Prove relay-token, endpoint-ID, cookie, and name-binding rejection layers.
- [x] Phase 6.5: Test relay outage, bounded diagnostics, readiness restoration, and explicit reconnect.
- [x] Phase 6.6: Integrate authoritative QA and complete the tested two-machine distribution workflow.
- [x] Phase 6.7: Pass the epic gate and commit the private-network cluster proof.

## Ordered Implementation

### Phase 6.1 — Relay-only fixtures and harness

1. Generate three unique node names, identity files, endpoint IDs, and exact reciprocal peer tables.
2. Configure only the pinned local custom relay with `direct_ip: false`; prohibit n0/public lookup.
3. Extend child commands/readiness for three independent OS processes.
4. Reuse the fixture relay token without printing it and provide wrong-token variants.
5. Add cleanup for all child trees, temp files, and native states.

**Exit:** three VMs reach distribution-endpoint readiness independently and all report relay-only configuration.

### Phase 6.2 — Commanded topology

1. Start the three VMs without auto-connect behavior.
2. Command explicit `Node.connect/1` calls to form the chosen full topology.
3. Assert each node sees exactly the expected two peers.
4. Query both ends of every link and require authenticated expected IDs and `:relay` paths.
5. Assert the child nodes start no EPMD child, register no EPMD names, expose no TCP distribution listener, and use no direct/public route.

**Exit:** all three nodes form the expected topology exclusively over Iroh relay links.

### Phase 6.3 — Relay semantics and load

1. Run ping, RPC success/error, PID/registered messages, links, process monitors, and node monitors across different pairs.
2. Transfer large terms/binaries and concurrent bidirectional streams of distribution traffic with hashes/sequences.
3. Keep the topology idle for multiple shortened tick intervals, then verify it remains healthy.
4. Disconnect/reconnect one pair without disturbing unrelated links.
5. Measure controller/native queues, resource counts, scheduler responsiveness, and cleanup under relay latency.

**Exit:** standard semantics and bounded data-plane invariants hold on all relay links.

### Phase 6.4 — Layered rejection

1. Start a peer with the wrong relay token and prove it cannot establish Iroh connectivity.
2. Start an authenticated but unconfigured endpoint and prove rejection before OTP handshake.
3. Use the expected endpoint ID with the wrong cookie and prove OTP handshake rejection.
4. Attempt a configured endpoint claiming another node name and prove no node-up.
5. Scan all child/container/telemetry/error outputs for token, cookie, key, ticket, and payload sentinels.

**Exit:** each security layer fails at its documented boundary without secret disclosure.

### Phase 6.5 — Relay outage and recovery

1. Establish healthy links, stop the only relay, and record whether existing paths remain or produce bounded node-down.
2. Require new connect attempts to fail while the relay route is unavailable.
3. Emit bounded Docker and child diagnostics on timeout/failure.
4. Restart the relay, wait for readiness, restart/rebind peers where Iroh requires it, and explicitly reconnect.
5. Assert fresh links use relay paths and stale controllers/resources are gone.

**Exit:** outage behavior is bounded/honest and explicit recovery is reproducible.

### Phase 6.6 — QA and physical workflow

1. Add the three-VM suite to the relay stage of `bin/qa_check.sh`.
2. Start or reuse Compose, poll readiness with a deadline, and dump status/log tails on failure.
3. Preserve explicit developer teardown instructions without destroying unrelated containers automatically.
4. Add/update a two-machine distribution example with dynamic and early startup sequencing.
5. Execute local substitutions of every example command/API in tests and document NAT/physical-network limitations.

**Exit:** one authoritative command runs relay proof and documentation is operationally accurate.

### Phase 6.7 — Epic verification

1. Run full `bin/qa_check.sh` with Docker from a clean relay state and once with relay reuse.
2. Verify all six link directions/path assertions and security/failure criteria.
3. Check no process/container/temp identity/native resource remains.
4. Review docs for membership, NAT, uptime, and automatic-healing overclaims.
5. Commit the green focused proof.

**Exit:** relay-only three-VM proof is committed with reproducible QA.

## Test Isolation Checklist

- [x] Every VM has a distinct identity, node name, temp root, and exact static table.
- [x] Public Iroh infrastructure and direct IP are disabled.
- [x] Parent harness never joins the distributed cluster.
- [x] Relay outage tests restore Compose state even after assertion failure.
- [x] Logs and diagnostics are bounded and redacted.

## Quality Gate

- [x] Three-node relay-only topology and all path assertions pass.
- [x] Relay OTP semantics, large/concurrent traffic, ticks, and boundedness pass.
- [x] Token/ID/cookie/name rejection ordering and redaction pass.
- [x] Outage/new-connect failure/recovery and cleanup pass.
- [x] Two-machine workflow is tested and full QA passes.

## Commit Rule

Commit only after full QA as `roadmap002 - epic 6 - prove relay-only beam clustering`. The body must state three distinct VMs/identities, explicit topology, relay path enforcement, layered rejection, outage/recovery result, and QA command.
