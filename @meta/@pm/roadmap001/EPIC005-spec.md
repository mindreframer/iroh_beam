# EPIC005 Spec: Bounded QUIC Streams and Datagrams

## Purpose

Expose Iroh's QUIC streams and datagrams as explicit, bounded Elixir transport primitives with backpressure, full-duplex progress, and unambiguous closure behavior.

## Reference Inputs

- `@meta/@pm/ROADMAP001.md`
- EPIC004 authenticated connection lifecycle
- Iroh/noq send-stream, receive-stream, and datagram APIs
- Iroh QUIC guidance on lazy streams and graceful closure

## Scope

In scope:

- open/accept for unidirectional and bidirectional streams
- send and receive halves, stream IDs, partial send, send-all convenience with limits, and explicit receive maximums
- EOF, finish, reset, stop, peer reset/stopped, and connection-loss translation
- datagram send, capacity-aware send, receive, and current maximum size
- configurable positive chunk and operation limits
- QUIC flow-control backpressure, one in-flight mutable operation per half, concurrent opposite halves, and cancellation
- reusable-connection echo/request-response examples and large bounded transfer tests

Out of scope:

- application message framing/serialization, RPC, codecs, GenStage/Broadway, or protocol-specific processes
- unbounded `read_to_end`, implicit term serialization, file transfer, stream priority, and 0-RTT
- guaranteed datagram delivery/order or automatic retransmission above QUIC

## Stream Contract

A bidirectional stream contains independently usable send and receive halves. The sender must transmit data before the peer can accept a lazily opened stream. `send` resolves under QUIC flow control; IrohBeam does not place writes in an unbounded fire-and-forget queue. `recv` requires a positive maximum allocation and returns `{:ok, binary}`, `:eof`, or a structured error. Any read-to-end convenience also requires an explicit hard limit.

Each mutable half allows one in-flight operation. Conflicting calls return a stable `:busy`-category error rather than waiting in an invisible unbounded lock queue. Sending and receiving on opposite halves remains concurrent. Timeout or caller death cancels only the pending operation; reset/stop/connection close unblocks affected callers.

Datagrams are optional, unreliable QUIC messages. Oversized sends fail before allocation/queueing where possible. Their API does not imply stream reliability.

## Acceptance Criteria

- Uni- and bidirectional open/accept pairs transfer exact bytes and expose stable stream IDs.
- EOF, finish, reset, stop, peer abort, and connection close produce documented results on both ends.
- A full-duplex test sends and receives concurrently without half-lock interference.
- Same-half conflicting operations fail deterministically and leave the winning operation usable.
- Large payloads transfer in bounded chunks with flow-control backpressure, bounded native queues, and responsive BEAM schedulers.
- Required receive limits reject zero, negative, oversized, and exhausted-limit cases before uncontrolled allocation.
- Datagram round trips and oversize/capacity errors match documented unreliable semantics.

## Test Strategy

- Run deterministic echo, uni notification, request/response, full-duplex, and reusable-connection scenarios.
- Transfer data materially larger than chunk/window limits and measure current/peak native queued bytes.
- Inject finish/reset/stop/close at exact barriers while readers/writers wait.
- Race same-half calls and verify `busy` behavior without deadlocks.
- Kill callers and endpoint owners during flow-control waits and assert operation/resource cleanup.
- Keep payload fixtures synthetic and bounded on CI.

## Quality Bar

- No public receive operation can allocate based on untrusted peer length without a caller limit.
- No unbounded native write/event queue exists.
- Full-duplex use is possible without spawning native state per byte/chunk.
- QUIC closure semantics are documented accurately rather than hidden behind TCP terminology.
- Full QA is green before commit.
