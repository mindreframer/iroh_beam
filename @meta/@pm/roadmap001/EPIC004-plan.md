# EPIC004 Plan: Authenticated Connections and Admission

## Progress

- [ ] Phase 4.1: Define dial-target, ALPN, connection-handle, acceptance, and resolution contracts.
- [ ] Phase 4.2: Implement cancellable outgoing connections by ID, address, and ticket.
- [ ] Phase 4.3: Implement bounded pull-based incoming acceptance and ALPN handling.
- [ ] Phase 4.4: Expose authenticated remote identity, side, close state, and selected-path snapshot.
- [ ] Phase 4.5: Add optional peer allowlists and stable refusal/timeout/cancellation behavior.
- [ ] Phase 4.6: Test direct connectivity, resolution modes, limits, races, cleanup, and scheduler responsiveness; document usage.
- [ ] Phase 4.7: Pass the epic gate and commit authenticated connections.

## Implementation Steps

1. Define one connect function accepting typed dial targets, validated ALPNs, explicit timeouts, and stable connection values.
2. Submit Iroh handshakes through the async operation bridge and preserve target-specific address-lookup semantics.
3. Own the endpoint accept future in native state, satisfy Elixir accept demand from a bounded queue, and cancel cleanly on close.
4. Add remote ID, negotiated ALPN, side, stable ID, path/RTT snapshot, close, closed, and close-reason operations.
5. Enforce authenticated-ID allowlists after handshake and normalize refusal, timeout, endpoint closure, and caller cancellation.
6. Add loopback direct, lookup fixture, ticket/address, ALPN, admission, saturation, race, repetition, cleanup, and responsiveness tests plus connection docs.
7. Run full QA, verify every criterion/non-goal, review the focused diff, and commit only when green.

## Test Isolation Checklist

- [ ] Direct tests use explicit loopback addresses and disabled relays.
- [ ] Lookup tests use a deterministic local fixture, never public DNS.
- [ ] Saturation/cancellation tests use barriers and bounded counters.
- [ ] Every connection and endpoint is explicitly closed in teardown.
- [ ] Tests do not transfer application payloads beyond handshake smoke bytes.

## Quality Gate

- [ ] ID/address/ticket dial, accept, ALPN, identity, admission, path, and close tests pass.
- [ ] Missing lookup, timeout, refusal, saturation, race, caller death, and cleanup tests pass.
- [ ] Scheduler responsiveness and no-public-fallback assertions pass.
- [ ] QA succeeds and no stream/datagram application API is included.
- [ ] Commit title/body follow the roadmap rule.

## Commit Rule

Run `bin/qa_check.sh`. Only after Epic 4 is complete, commit as `roadmap001 - epic 4 - <authenticated connection outcome>` with a body summarizing dialing, admission, lifecycle, and verification.
