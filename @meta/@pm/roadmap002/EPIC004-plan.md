# EPIC004 Plan: Bounded Distribution Data Plane

## Progress

- [x] Phase 4.1: Add bounded native iodata sending and distribution stream primitives.
- [x] Phase 4.2: Implement the packet-four incremental input parser and input handler.
- [x] Phase 4.3: Implement notification-driven, one-write-at-a-time emulator output.
- [x] Phase 4.4: Complete handshake transition, controller registration, ticks, stats, and options.
- [x] Phase 4.5: Prove RPC, process messages, large terms, and concurrent bidirectional traffic.
- [x] Phase 4.6: Prove backpressure, bounded memory/mailboxes, scheduler responsiveness, and cleanup.
- [x] Phase 4.7: Pass the epic gate and commit the production distribution data plane.

## Ordered Implementation

### Phase 4.1 — Native distribution I/O primitives

1. Add an internal async send accepting validated bounded iodata/iovecs and an explicit byte count.
2. Copy/retain terms safely before returning from the NIF; never hold borrowed `Env` data across async work.
3. Reuse one stream send lease and existing QUIC flow control with one write in flight.
4. Add a bounded receive primitive or reuse the existing one with distribution-specific ownership/cancellation.
5. Expose test snapshots for in-flight reads/writes and queued bytes without public API expansion.

**Exit:** nested iodata and max-bound tests pass; invalid/oversized input fails synchronously and network waits remain async.

### Phase 4.2 — Packet-four input

1. Implement parser state for partial header/body and handshake residue.
2. Parse multiple frames per chunk while yielding/bounding work to avoid monopolizing a scheduler.
3. Validate length before body allocation and cap retained bytes.
4. Feed complete packets, including zero-length ticks, through `dist_ctrl_put_data/2`.
5. Keep one receive operation in flight and close on EOF/reset/malformed/oversized frames.

**Exit:** exhaustive split/coalesce/parser-limit tests pass with bounded retained memory.

### Phase 4.3 — Emulator output

1. Enable distribution-handle size reporting and request data notifications.
2. Pull one emulator packet only when no native write is pending.
3. Validate packet size, frame it as four-byte length plus iovec, and submit async.
4. Re-arm notifications only after data is drained and preserve notification race correctness.
5. Handle write completion/error/close without accumulating stale `dist_data` or completion messages.

**Exit:** deterministic barriers prove at most one pulled/pending packet and no notification loss.

### Phase 4.4 — Controller transition and ticks

1. Replace the Epic 3 holder with linked output controller and input handler processes.
2. Register the input handler and synchronize `f_handshake_complete` before acknowledging node-up continuation.
3. Implement idle tick coalescing and ensure data/write states cannot lose close/tick signals.
4. Use emulator stats where valid; implement only required get/set options with explicit errors.
5. Link all owners so any fatal half failure closes stream, QUIC connection, and distribution handle path.

**Exit:** one controller/input pair owns each link; idle ticks and all owner-death permutations behave within bounds.

### Phase 4.5 — Functional data-plane proof

1. Test `Node.ping/1`, RPC calls/returns, and direct process messaging in both directions.
2. Send binaries/terms below, equal to, and far above receive chunk size with hash verification.
3. Run many concurrent senders and RPCs bidirectionally with sequence accounting.
4. Exercise registered sends, remote spawn where supported, and error replies without yet claiming full Epic 5 semantics.
5. Record observed maximum distribution frame under fragmentation and validate defaults.

**Exit:** data is complete/correct under large and concurrent direct traffic.

### Phase 4.6 — Boundedness and responsiveness

1. Pause/slow native send and remote consumption at deterministic barriers.
2. Measure controller mailboxes, native queued bytes, process/BEAM memory, and resource counts after warm-up.
3. Assert configured envelopes and plateau over repeated connect/traffic/disconnect cycles.
4. Run scheduler responsiveness probes during blocked reads/writes and large traffic.
5. Test oversized frame, malformed stream, reset, endpoint close, handler death, and owner death cleanup.

**Exit:** no unbounded queue, mailbox, memory growth, scheduler stall, or orphan resource is observed.

### Phase 4.7 — Epic verification

1. Remove the temporary holder and all superseded test-only paths.
2. Run full `bin/qa_check.sh`.
3. Verify parser/backpressure/tick/cleanup criteria and inspect measurement tolerances for honesty.
4. Scan diagnostics for packets/payloads/secrets and review Rust unsafe/panic/error paths.
5. Commit the focused green data plane.

**Exit:** production bounded direct distribution data plane is committed.

## Test Isolation Checklist

- [x] Parser/property tests need no sockets or child VMs.
- [x] Stress tests use fixed seeds, bounded payload totals, and explicit warm-up/measurement windows.
- [x] Slow-reader barriers are deterministic rather than scheduler timing guesses.
- [x] Child VMs and controllers are forcibly cleaned after failures.
- [x] Memory/queue assertions document platform tolerance and do not rely on exact allocator release.

## Quality Gate

- [x] Native iodata and packet-four parser suites pass.
- [x] Direct ping/RPC/large/concurrent/tick tests pass.
- [x] One-read/one-write, queue, mailbox, memory, scheduler, and resource bounds pass.
- [x] Every close/death path emits bounded node-down and cleans resources.
- [x] Full QA passes.

## Commit Rule

Commit only after full QA as `roadmap002 - epic 4 - add bounded distribution data plane`. The body must summarize process-controller registration, parser/backpressure invariants, large/concurrent/tick evidence, measured bounds, and QA command.
