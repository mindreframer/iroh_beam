# EPIC001 Spec: OTP 29 Carrier Foundation and Compatibility Gate

## Purpose

Turn the researched OTP alternative-carrier approach into an executable, reviewable foundation before opening any Iroh distribution connection. This epic fixes the supported runtime, callback surface, module ownership, package layout, and quality gate so later epics do not discover boot or compatibility constraints accidentally.

## Reference Inputs

- `@meta/@pm/ROADMAP002.md`
- IrohBeam `0.1.0` implementation and ROADMAP001 contracts
- OTP `29.x` `net_kernel`, `dist_util`, `inet_tcp_dist`, `inet_epmd_dist`, and `inet_epmd_socket`
- OTP documentation for alternative distribution carriers and process distribution controllers

## Scope

In scope:

- ADR for direct Iroh carrier versus TCP tunnel/sidecar and for OTP-owned semantics
- explicit OTP `29.x` compile/runtime support check
- Erlang source compilation and package inclusion
- internal module boundaries for `iroh_dist`, configuration, endpoint ownership, and controller ownership
- the complete `iroh_dist` callback skeleton with deterministic unsupported/not-ready behavior
- callback-shape, boot-order, child-spec, address-record, creation, and error-path tests
- a separate-OS-process test harness that does not rely on distributed Erlang as its control plane
- QA and CI stages needed by all later distribution work

Out of scope:

- binding a distribution Iroh endpoint
- dialing or accepting Iroh connections
- constructing live `#hs_data{}` callbacks
- calling `erlang:dist_ctrl_*`
- `Node.connect/1` success
- relay testing or public API documentation beyond the foundation contract

## Required Design

The carrier module is named `iroh_dist` because OTP resolves `-proto_dist iroh` to that module. It implements the OTP 29 callback arities used by `net_kernel`:

- `childspecs/0`
- `listen/1` and `listen/2`
- `accept/1`
- `accept_connection/5`
- `setup/5`
- `close/1`
- `select/1`
- `address/0` and `address/1`

Optional `setopts/2` and `getopts/2` are added only if OTP invokes them for process controllers; unsupported options must return explicit errors. The implementation uses OTP's kernel include files rather than copying record definitions.

`iroh_dist:childspecs/0` returns one early-worker child specification but the worker remains a deterministic non-network stub in this epic. The stub proves that protocol child specs are started before `net_kernel`, can load package code, and do not require the normal IrohBeam application supervisor.

The package targets OTP `29.x`. A single guard module owns the version check. Unsupported OTP versions must produce a short actionable error naming the supported major; code must not scatter release comparisons through carrier modules.

The OS-process harness uses `Port`/`System.cmd`-style child processes, bounded startup/output timeouts, unique temporary directories, and explicit teardown. Child VMs emit a small line-delimited control format over stdio or files. The harness must not use EPMD or an already distributed parent VM to coordinate the test.

## Acceptance Criteria

- `-proto_dist iroh` resolves and loads `iroh_dist` on OTP 29.
- Erlang source compiles with warnings treated as errors and is included in an unpacked Hex package.
- The centralized support guard accepts OTP 29 and returns a deterministic unsupported-runtime error for simulated non-29 versions.
- Every required carrier callback is exported and has a focused contract test.
- The early child-spec stub starts in the expected order for dynamic and early named-node probes without loading telemetry or the IrohBeam application supervisor.
- Listener creation values are valid non-small 32-bit incarnations and are not persisted or reused deliberately.
- Unimplemented live operations fail cleanly; no callback hangs, starts TCP distribution, registers with EPMD, or opens Iroh sockets.
- The separate-VM harness starts, observes, times out, and forcibly cleans child VMs without relying on distributed Erlang.
- `bin/qa_check.sh` and pinned CI are green.

## Test Strategy

- Compile-time assertions for Erlang exports and OTP header availability.
- Unit tests for support guards, node-name splitting inputs, creation generation, address records, and error normalization.
- A protocol boot probe with `-proto_dist iroh -no_epmd` and no node name.
- An early named-node negative probe that reaches the intentional not-ready boundary and exits with the documented reason.
- Package unpack audit for `src/*.erl`/compiled application inputs as appropriate.
- Harness tests for successful child output, startup timeout, nonzero exit, output truncation, and process-tree cleanup.
- Socket/process assertions proving the foundation does not start EPMD, a TCP listener, or an Iroh endpoint.

## Quality Bar

- OTP internals used by the design are named and pinned to OTP 29, not treated as stable across untested releases.
- No copied OTP source or record layout is introduced.
- Early modules have no dependency on Mix, telemetry startup, Logger startup assumptions, or an application supervisor.
- Errors crossing early boot are printable without Elixir protocol dependencies.
- The test harness always tears down children on assertion failure and emits bounded diagnostics.
- Existing IrohBeam `0.1.0` transport tests remain unchanged and green.
