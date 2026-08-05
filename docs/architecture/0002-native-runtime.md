# ADR 0002: Native runtime and operation ownership

## Status

Accepted for ROADMAP001.

## Decision

A loaded `iroh_beam_nif` owns one multithreaded Tokio runtime. Normal-scheduler
NIF calls may perform bounded validation and atomic/resource operations, but may
not bind, wait, perform network I/O, or call `Runtime::block_on`.

Async calls use this protocol:

1. Elixir creates an operation reference and supplies its caller PID.
2. Native code creates a monitored operation resource and submits a future.
3. Completion sends `{IrohBeam.Native, reference, result}` exactly once.
4. Explicit cancellation, caller death, or timeout marks the operation cancelled
   and wakes its future; cancelled operations do not send late results.
5. Elixir translates native maps into `%IrohBeam.Error{}` and suppresses any
   already-cancelled reference.

Resources are internally synchronized. Future endpoint, connection, and stream
resources have explicit asynchronous close operations. Drop callbacks only
abort; they never wait for runtime work.
