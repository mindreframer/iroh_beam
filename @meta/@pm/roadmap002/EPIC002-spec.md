# EPIC002 Spec: Distribution Endpoint, Configuration, and Static Admission

## Purpose

Create the dedicated Iroh endpoint and immutable peer configuration required by distribution, with correct early-boot ownership and rejection of unknown identities before any OTP handshake is exposed.

## Reference Inputs

- `@meta/@pm/ROADMAP002.md`
- EPIC001 carrier/boot/support contracts
- Existing `IrohBeam.Identity`, endpoint address/ticket, relay, endpoint, connection, and native resource behavior
- OTP 29 protocol child-spec and distribution-supervisor sequencing

## Scope

In scope:

- one canonical distribution configuration schema shared by dynamic and early startup
- exact node-atom to Iroh target normalization
- dedicated distribution endpoint worker and native ownership
- fixed distribution ALPN `iroh-beam/erlang-distribution/1`
- outgoing resolution/dial primitives and incoming connection/stream acceptance primitives
- endpoint-ID allowlisting before OTP handshake
- dynamic `IrohBeam.Distribution.start/1` bootstrap and internal early-boot configuration loading
- safe local status and deterministic stop/rollback behavior before node links exist

Out of scope:

- OTP handshake callbacks and `Node.connect/1` success
- post-handshake process distribution controllers
- dynamic peer mutation, custom resolver behavior, wildcard admission, or membership
- relay-only multi-VM acceptance (Epic 6)

## Configuration Contract

Required dynamic options:

- `:name` — exact local node atom containing one `@`
- `:name_domain` — `:shortnames` or `:longnames`
- `:identity` — existing ephemeral/file/secret-key identity input; production docs require persistent identity
- `:network` — existing supported Iroh network profile
- `:peers` — map of exact remote node atoms to explicit Iroh targets

Supported peer targets are typed `EndpointId`, `EndpointAddr`, `EndpointTicket`, or tagged serialized forms `{:id, text}`, `{:addr, value}`, and `{:ticket, text}`. Every peer target yields one canonical endpoint ID. Duplicate endpoint IDs assigned to different node names are rejected in `0.2.0` because exact identity binding would be ambiguous.

Distribution-specific bounded options include startup/shutdown/dial/accept/stream timeouts, receive chunk, maximum frame, and connection count. Defaults are fixed and documented; unknown keys and conflicting options fail before starting distribution.

The normalized configuration is immutable for the life of the distribution endpoint. It must not retain unredacted serialized secret keys, relay tokens, or ticket text in status/log output.

## Endpoint Ownership Contract

`iroh_dist:childspecs/0` starts one `iroh_dist_endpoint` worker before `net_kernel`. The worker owns:

- one distinct native Iroh endpoint identity;
- one outstanding accept operation;
- normalized peer node/endpoint-ID indexes;
- all pending outgoing setup operations;
- accepted connections awaiting OTP setup;
- safe counters and connection metadata.

The worker uses the low-level native API without depending on `IrohBeam.Endpoint` GenServer, application telemetry startup, or a second supervisor. Existing native resources may be reused, but ownership/transfer must be explicit and tested. Worker death aborts accepts and closes all resources without blocking its supervisor.

Incoming acceptance first verifies the fixed ALPN and authenticated remote endpoint ID. Unknown IDs close at Iroh level and are never handed to `dist_util`. An admitted connection accepts exactly one bidirectional stream; unidirectional or extra stream attempts are rejected/closed.

## Startup Modes

`IrohBeam.Distribution.start/1`:

1. validates options without changing VM distribution state;
2. installs a redacted/normalized bootstrap configuration;
3. calls OTP's supported dynamic `net_kernel` start API;
4. waits for the distribution endpoint to report ready within a bound;
5. rolls back configuration/resources on any failure.

It requires the VM to have `-proto_dist iroh -no_epmd` in init arguments and to be unnamed. Clear errors cover already distributed, wrong protocol, EPMD-enabled unsupported launch, duplicate endpoint, and malformed configuration.

Early startup reads the same schema from boot-time application environment. Missing/late configuration fails before listener registration with actionable text. The docs must distinguish boot-time `sys.config` from configuration providers evaluated after kernel distribution startup.

## Acceptance Criteria

- Valid configuration normalizes deterministically to exact node and endpoint-ID indexes.
- Invalid names, duplicate IDs, unknown options, malformed targets, unsafe limits, and identity/network errors fail without changing distribution state.
- One dedicated endpoint starts with the fixed ALPN in both dynamic and early boot probes.
- Starting a second distribution endpoint is rejected and leaves the first untouched.
- A configured direct-mode peer can establish an authenticated Iroh connection and exactly one bidirectional stream through internal primitives.
- An unknown endpoint ID is rejected before any OTP handshake callback is invoked.
- Endpoint worker death, startup failure, stop, and caller failure leave no accept, operation, stream, connection, endpoint, or socket resource.
- Status is bounded and redacted.
- Full QA passes.

## Test Strategy

- Table-driven pure configuration tests, including atom safety and duplicate identity cases.
- Dynamic startup rollback tests for every validation and native bind failure stage.
- Early boot probes with valid boot environment, missing configuration, and deliberately late configuration.
- Two separate child VMs/endpoint probes using direct loopback addresses and distinct identities, but a test preface rather than OTP handshake.
- Unknown-ID, wrong-ALPN, uni-stream, extra-stream, timeout, caller-death, and worker-death tests.
- Native snapshots and OS socket checks before/after repeated start-stop cycles.
- Redaction scans using known secret, cookie-like, ticket, and relay-token fixtures.

## Quality Bar

- One validation implementation serves both startup modes.
- No remote input creates atoms or configuration entries.
- Endpoint admission is based on Iroh-authenticated IDs, not peer-provided metadata.
- No unbounded accept loop, mailbox, stream wait, or native operation exists.
- Early startup emits no telemetry before dependencies are available.
- Existing general-purpose endpoints can coexist and remain API-compatible.
