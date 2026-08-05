# EPIC002 Plan: Distribution Endpoint, Configuration, and Static Admission

## Progress

- [ ] Phase 2.1: Define and implement the immutable distribution configuration schema.
- [ ] Phase 2.2: Implement exact static peer normalization, indexes, and redaction.
- [ ] Phase 2.3: Replace the inert child with the dedicated native distribution endpoint worker.
- [ ] Phase 2.4: Add bounded outgoing dial and incoming admitted-stream primitives.
- [ ] Phase 2.5: Implement dynamic startup, early-boot loading, readiness, rollback, and stop.
- [ ] Phase 2.6: Prove admission, ownership, redaction, coexistence, and resource cleanup.
- [ ] Phase 2.7: Pass the epic gate and commit the endpoint/configuration layer.

## Ordered Implementation

### Phase 2.1 — Canonical schema

1. Define required and optional keys, defaults, units, and hard ranges in one internal configuration module.
2. Validate local node atom/name domain, identity, network, timeouts, receive chunk, max frame, and capacities.
3. Reject unknown keys and values that conflict with the selected network profile.
4. Keep validation pure until all options pass.
5. Expose only a redacted diagnostic representation.

**Exit:** table-driven valid/invalid configuration tests pass without starting native state.

### Phase 2.2 — Static peer table

1. Normalize typed and tagged ID/address/ticket targets through existing public value rules.
2. Build exact node-to-target, node-to-ID, and ID-to-node indexes.
3. Reject malformed node atoms, local-node entries, duplicate nodes, duplicate endpoint IDs, and wildcard-like names.
4. Ensure only configured atoms are retained; never atomize serialized or remote text.
5. Add safe lookup functions for outgoing resolution, incoming ID admission, and later name binding.

**Exit:** all lookup paths are deterministic, immutable, exact, and redacted.

### Phase 2.3 — Dedicated endpoint worker

1. Implement the protocol child spec and early worker without using the normal application supervisor.
2. Load/create the configured identity and bind one native endpoint with only the fixed distribution ALPN.
3. Publish readiness and safe endpoint ID/status to an internal registry.
4. Start one bounded accept operation and restart it only after completion.
5. On terminate, cancel accepts/dials and abort resources without waiting in a destructor.

**Exit:** dynamic and boot probes start/stop one endpoint repeatedly with resource snapshots returning to baseline.

### Phase 2.4 — Connection and stream primitives

1. Resolve configured outgoing nodes and dial their exact targets.
2. Verify the resulting authenticated remote ID equals the configured ID.
3. For incoming connections, reject IDs absent from the ID index before any handshake owner is started.
4. Open/accept one bidirectional stream and reject wrong ALPN, uni streams, extras, and bounded timeouts.
5. Define explicit ownership transfer from endpoint worker to future setup/controller processes.

**Exit:** separate direct-mode child VMs exchange a bounded test preface only when both ID and ALPN are valid.

### Phase 2.5 — Startup paths

1. Implement `IrohBeam.Distribution.start/1` validation and protocol/init-argument checks.
2. Install bootstrap configuration, call dynamic `net_kernel` startup, and await endpoint readiness.
3. Roll back application/bootstrap state and native resources on every failure.
4. Implement early loading from boot-time application environment using the same validator.
5. Add `stop/0` for dynamic mode and explicit errors for already named, wrong protocol, duplicate endpoint, and unsupported sequencing.

**Exit:** dynamic and early paths converge on identical normalized state; late config fails with actionable diagnostics.

### Phase 2.6 — Security and lifecycle proof

1. Test configured peer success and unknown ID rejection before the handshake marker.
2. Test wrong ALPN, malformed target, duplicate ID, accept/dial timeout, owner death, and endpoint worker death.
3. Repeat startup/stop and general-endpoint coexistence until native resources/sockets plateau.
4. Scan status/errors/logs for known secret, ticket, token, and payload fixtures.
5. Assert the child node starts no EPMD child, registers no EPMD name, and exposes no TCP distribution listener.

**Exit:** admission ordering, redaction, coexistence, and deterministic cleanup are evidenced by tests.

### Phase 2.7 — Epic verification

1. Run full `bin/qa_check.sh`.
2. Verify all spec criteria and the no-handshake/no-Node-connect scope boundary.
3. Review native and Erlang ownership paths for late completions and orphan resources.
4. Update only evidence-backed checkboxes.
5. Commit the green epic.

**Exit:** clean commit with direct preface/admission proof and no OTP handshake yet.

## Test Isolation Checklist

- [ ] Identities and bind addresses are unique per child VM/test.
- [ ] Direct tests use loopback/static addresses and no public lookup.
- [ ] Unknown peers never reach the handshake test marker.
- [ ] Startup tests restore application/bootstrap environment.
- [ ] Child and native resources are cleaned on timeout and assertion failure.

## Quality Gate

- [ ] Schema, peer indexes, atom safety, duplicate rejection, and redaction pass.
- [ ] Dynamic and early endpoint startup/rollback pass.
- [ ] Configured direct preface succeeds; unknown ID/wrong ALPN fails before handshake.
- [ ] Repeated ownership/resource tests plateau.
- [ ] Full QA passes with no `Node.connect/1` success introduced.

## Commit Rule

Commit only after full QA as `roadmap002 - epic 2 - add distribution endpoint and static admission`. The body must mention the immutable schema, early/dynamic startup evidence, pre-handshake ID rejection, resource plateau, and QA command.
