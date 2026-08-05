# EPIC004 Spec: Bounded Distribution Data Plane

## Purpose

Replace the temporary post-handshake holder with a production process distribution controller that moves opaque OTP distribution packets over Iroh with bounded framing, flow control, ticks, and deterministic shutdown.

## Reference Inputs

- `@meta/@pm/ROADMAP002.md`
- EPIC003 live OTP handshake and stream/session ownership
- OTP 29 `inet_epmd_socket` process-controller pattern and `erlang:dist_ctrl_*` documentation
- Existing IrohBeam bounded stream implementation and native operation counters

## Scope

In scope:

- `f_handshake_complete` transition to an OTP process distribution controller
- linked input and output handler ownership around one distribution handle
- packet-four data framing after handshake
- bounded incremental parsing of split/coalesced frames
- pull-based emulator output with one native write in flight
- native iodata/iovec send support suitable for distribution output
- one bounded native read in flight, QUIC flow control, and explicit maximum frame
- ticks, emulator distribution statistics, supported net-kernel option behavior, and close propagation
- RPC, process messaging, large binaries/terms, concurrent traffic, idle links, and scheduler/memory tests

Out of scope:

- changing OTP distribution encoding or flags
- application-level compression, serialization, retries, or exactly-once behavior
- relay-only tests and broad fault recovery (Epics 5–6)
- zero-copy claims not proven by measurement

## Controller Contract

After OTP calls `f_handshake_complete`, the setup/con-loop process synchronizes with a linked controller. The controller registers a linked input handler through `erlang:dist_ctrl_input_handler/2`, requests output notifications, and acknowledges transition only after both handlers can make progress.

Output loop:

1. request `erlang:dist_ctrl_get_data_notification/1`;
2. on `dist_data`, pull one `{length, iovec}` packet with size reporting enabled;
3. validate the length against `max_frame`;
4. send `<<length::32, iovec::iodata>>` through one async native operation;
5. do not pull another packet until the write completes;
6. coalesce an idle tick only when no data/write is pending.

Input loop:

1. keep exactly one bounded receive operation in flight;
2. append at most `max_frame + 4` incomplete bytes plus one receive chunk;
3. parse zero or more complete four-byte frames without recursive unbounded work;
4. reject a length greater than `max_frame` before allocating its body;
5. pass complete packet iodata/binaries to `erlang:dist_ctrl_put_data/2`;
6. deliver zero-length frames as ticks and continue.

The controller accepts arbitrary QUIC chunk boundaries: partial header, partial body, multiple frames, and handshake residue. It avoids repeated whole-buffer concatenation and quadratic copying.

## Backpressure and Memory Contract

- At most one output packet is held by the Erlang controller and one copied/buffered packet by the native send path.
- The native send API accepts bounded iodata/iovecs; decoding/copying occurs quickly and never waits for network capacity in a NIF.
- Output waits for QUIC capacity asynchronously before pulling more emulator data.
- Input never has more than one receive chunk plus one bounded incomplete frame.
- Mailboxes are sampled under stress; no message class may grow without a configured bound.
- Large Erlang messages are expected to use OTP's negotiated fragmentation. Tests record observed frame maxima and fail if configuration cannot carry negotiated packets safely.

## Tick and Option Contract

`mf_tick` sends/coalesces a zero-length packet-four frame through the output owner. `mf_getstat` may remain undefined when OTP 29's emulator distribution statistics are sufficient; otherwise it returns monotonic receive/send/pending values. `mf_setopts` and `mf_getopts` support only options OTP/net_kernel actually requires and return explicit bad-option errors for unsupported transport-specific requests.

Idle direct links are tested with shortened but non-flaky tick settings for multiple tick intervals. A blocked data write must not permanently suppress ticks or closure detection.

## Acceptance Criteria

- The temporary holder is removed and every connected node has one registered process distribution controller plus one linked input handler.
- `Node.ping/1`, small and large RPC/process messages, binaries, and concurrent bidirectional traffic are correct over direct Iroh links.
- Packet-four parser tests cover every header/body split, coalesced frames, zero-length ticks, maximum legal frame, oversized length, EOF, and residue transition.
- Output pulls only when capacity exists and keeps at most one native write in flight.
- Input keeps at most one native read in flight and bounded incomplete state.
- Slow receivers produce backpressure without scheduler stalls, unbounded controller/native queues, or silent data loss.
- Idle links remain up across multiple tick intervals; stalled/closed links produce bounded `nodedown`.
- Controller/input/setup/endpoint death closes the full resource graph and unblocks callers.
- Queue, memory, mailbox, native-resource, and scheduler measurements stay within documented envelopes.
- Full QA passes.

## Test Strategy

- Property/table tests for packet-four parser chunking and frame sequences.
- Native iodata tests with nested iolists, ref-counted binaries, empty segments, invalid iodata, and max lengths.
- Separate-VM direct tests for RPC and raw process messages from bytes to materially larger than receive chunks.
- Many concurrent senders in both directions with deterministic hashes/sequence accounting.
- A controlled slow receiver and paused native-send barrier to inspect backpressure and mailbox/queue peaks.
- Tick endurance, blocked-output tick, connection close, stream reset, input death, output death, and distribution owner death.
- Repeated connect/traffic/disconnect cycles with BEAM memory, process mailbox, and native snapshot baselines.
- Scheduler responsiveness probes while reads and flow-controlled writes are pending.

## Quality Bar

- No controller loop uses unbounded `receive`, list accumulation, binary concatenation, or retry spinning.
- No native call waits for Iroh capacity on a normal scheduler.
- Frame lengths are validated before allocation and arithmetic is overflow-safe in Erlang and Rust.
- The distribution controller is linked/registered exactly as OTP 29 requires; it does not impersonate a port.
- Raw distribution packets and application payloads never appear in logs, telemetry, or errors.
