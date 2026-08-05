# EPIC005 Plan: Bounded QUIC Streams and Datagrams

## Progress

- [x] Phase 5.1: Define stream-half, bounded I/O, EOF, closure, concurrency, and datagram contracts.
- [x] Phase 5.2: Implement uni/bi stream open and accept resources.
- [x] Phase 5.3: Implement bounded backpressured send/receive and explicit finish/EOF.
- [x] Phase 5.4: Implement reset, stop, peer-abort, cancellation, and same-half busy behavior.
- [x] Phase 5.5: Add validated datagram send/receive and capacity/size reporting.
- [x] Phase 5.6: Add protocol examples and full-duplex, large-transfer, memory, scheduler, race, and cleanup tests.
- [x] Phase 5.7: Pass the epic gate and commit bounded transport I/O.

## Implementation Steps

1. Define Elixir stream/half values, mandatory receive limits, partial/all send behavior, EOF shapes, abort codes, and datagram semantics.
2. Wrap Iroh send/receive streams as separately synchronized resources and add uni/bi open/accept calls.
3. Route reads/writes through cancellable native futures, honor flow control, bound chunks/queues, and implement finish/EOF.
4. Add reset/stop/stopped/reset-received handling; reject concurrent mutable operations on one half without blocking opposite-half progress.
5. Add datagram maximum/capacity checks, immediate and capacity-waiting send, and bounded receive.
6. Implement tested echo/request/response/notification examples and deterministic large, full-duplex, abort, race, caller-death, memory, and responsiveness scenarios.
7. Run full QA, confirm every criterion/non-goal, inspect buffering/resource behavior, and commit only when green.

## Test Isolation Checklist

- [x] Tests use loopback endpoints, explicit addresses, and disabled relays.
- [x] Large fixtures exceed configured buffers but stay deterministic for CI.
- [x] Abort/race tests synchronize with barriers rather than sleeps.
- [x] Native queue/memory assertions use operation counters and documented tolerance.
- [x] Every stream, connection, and endpoint is closed or aborted in teardown.

## Quality Gate

- [x] Uni/bi, bounded I/O, EOF, abort, full-duplex, busy, and datagram tests pass.
- [x] Large-transfer buffering, backpressure, caller-death, cleanup, and scheduler tests pass.
- [x] Examples execute under automated tests.
- [x] QA succeeds and no application protocol/RPC/serialization layer is introduced.
- [x] Commit title/body follow the roadmap rule.

## Commit Rule

Run `bin/qa_check.sh`. Only after Epic 5 is complete, commit as `roadmap001 - epic 5 - <bounded QUIC I/O outcome>` with a body summarizing stream/datagram semantics, limits, and verification.
