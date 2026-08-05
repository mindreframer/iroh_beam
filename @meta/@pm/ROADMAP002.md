# ROADMAP002 — Native Erlang Distribution over Iroh

- **Status:** In Progress
- **Target release:** `0.2.0`
- **Depends on:** IrohBeam `0.1.0` / ROADMAP001
- **Supported runtime:** Elixir `~> 1.20` on OTP `29.x`
- **Native baseline:** Iroh `1.0.3`, Rust `1.91`, Rustler `0.38.0`, NIF `2.16`
- **Distribution protocol:** `iroh_dist` selected with `-proto_dist iroh`
- **Discovery model:** exact static node-to-Iroh-target configuration; no EPMD

## 1. Product Goal

Add an opt-in Erlang distribution carrier that lets ordinary BEAM nodes establish native distribution links over authenticated Iroh QUIC connections. Once connected, applications continue to use OTP's standard interfaces and semantics:

```elixir
Node.connect(:"worker@west")
Node.list()
Node.ping(:"worker@west")
:rpc.call(:"worker@west", MyModule, :run, [argument])
```

IrohBeam transports the distribution byte stream; OTP still performs the distribution handshake, cookie challenge, distribution term encoding, links, monitors, exit signals, ticks, node-up/down handling, and simultaneous-connect resolution. The implementation must not recreate those semantics in Rust or introduce a TCP tunnel.

The initial release deliberately uses explicit static discovery. Each configured Erlang node atom maps to one existing Iroh dialing value (`EndpointId`, `EndpointAddr`, or `EndpointTicket`), and therefore to one authenticated endpoint ID. Membership remains application-owned: IrohBeam neither decides which nodes should form a cluster nor automatically calls `Node.connect/1`.

## 2. User Experience

### Dynamic startup after application configuration

Dynamic startup is the preferred development and embedded path because application/runtime configuration is already available:

```elixir
{:ok, _pid} =
  IrohBeam.Distribution.start(
    name: :"api@east",
    name_domain: :shortnames,
    identity: {:file, "data/api.iroh"},
    network: :n0,
    peers: %{
      :"worker@west" => {:ticket, System.fetch_env!("WORKER_IROH_TICKET")}
    }
  )

Node.connect(:"worker@west")
```

The VM must have been launched with the protocol available but without starting named distribution early:

```console
elixir --erl "-proto_dist iroh -no_epmd" -S mix run --no-halt
```

### Early named-node startup

Releases that start distribution during kernel boot may launch with:

```console
erl -proto_dist iroh -no_epmd -sname api@east ...
```

The distribution configuration for this mode must already be present in boot-time application environment (`sys.config` or equivalent). Configuration providers evaluated after kernel distribution starts, including a late `runtime.exs`, are too late. This sequencing must be tested and documented rather than inferred.

Both modes use the same validated schema and transport implementation. Starting a second Iroh distribution endpoint in one VM is rejected.

## 3. Architecture Decisions

### Direct alternative carrier, not TCP-over-Iroh

`iroh_dist` implements the OTP alternative distribution callbacks (`listen`, `accept`, `accept_connection`, `setup`, `select`, `address`, and `close`) directly. One Erlang distribution connection uses one authenticated Iroh QUIC connection and one bidirectional stream negotiated under the fixed ALPN `iroh-beam/erlang-distribution/1`.

A local TCP proxy is not part of the product. It would retain EPMD/port-routing concerns, add two extra sockets and copies per link, and make failure ownership ambiguous.

### OTP 29 process distribution controllers

After the standard OTP handshake, a linked Erlang controller process becomes the low-level distribution controller through OTP 29's `erlang:dist_ctrl_*` API. The controller:

- pulls encoded distribution packets from the emulator only when native send capacity is available;
- frames post-handshake packets with a four-byte big-endian length;
- submits at most one bounded stream write at a time;
- receives bounded stream chunks and incrementally parses packet-four frames;
- feeds complete packets back through `erlang:dist_ctrl_put_data/2`;
- carries zero-length tick packets and uses emulator distribution statistics;
- closes the Iroh stream and connection when any linked owner exits.

Before node-up, the same stream carries OTP's packet-two handshake through `#hs_data{}` callbacks. Rust transports opaque bytes and owns no Erlang distribution terms, cookies, node atoms, links, or monitors.

The implementation targets OTP `29.x` only in `0.2.0`. It may use OTP 29 kernel headers and controller APIs, but must fail at compile/startup with a clear unsupported-runtime error elsewhere. Broader OTP support requires a later roadmap and CI evidence, not untested compatibility branches.

### One dedicated endpoint per VM

`iroh_dist:childspecs/0` installs an early distribution endpoint service under OTP's distribution supervisor. That service owns a dedicated native Iroh endpoint, the accept loop, normalized peer table, and connection registry. It does not depend on the normal IrohBeam application supervisor or telemetry application being started.

The public application transport API remains available and separate. A general `IrohBeam.Endpoint` is never silently reused as the VM-wide distribution endpoint.

### Static discovery and exact identity binding

The supported peer schema is an exact map from configured node atoms to explicit targets:

```elixir
peers: %{
  :"worker@west" => {:ticket, "..."},
  :"db@north" => {:id, "..."},
  :"cache@south" => {:addr, %{endpoint_id: "...", relay_urls: [], ip_addrs: []}}
}
```

Typed `IrohBeam.EndpointId`, `IrohBeam.EndpointAddr`, and `IrohBeam.EndpointTicket` values are also accepted. Every value normalizes to an endpoint ID plus dialing information.

The normalized table has three jobs:

1. `select/1` and outgoing `setup/5` resolve only exact configured node atoms.
2. Incoming QUIC connections reject endpoint IDs absent from the configured allowlist before the OTP handshake begins.
3. The claimed Erlang node name is restricted to exact configured names before atom creation and is checked against the authenticated endpoint ID before `nodeup`.

No remote string is converted to an atom unless it matches a pre-existing configured node name. Wildcard node names and allow-all admission are not supported in `0.2.0`.

### No EPMD, but no membership service either

The carrier never calls EPMD. Supported launch instructions include `-no_epmd`; tests verify no EPMD registration or TCP distribution listener is used. A custom `-epmd_module` is unnecessary for the static release and is not implemented.

Static resolution is not membership. Applications may manually call `Node.connect/1` or use their own membership component to choose among already configured node atoms. A dynamic registry, endpoint-ID node-name convention, and `libcluster` strategy are deferred until the carrier is proven.

## 4. Wire and Security Contract

For each distribution link:

1. Dial the configured Iroh target with ALPN `iroh-beam/erlang-distribution/1`.
2. Verify Iroh's authenticated remote endpoint ID against the expected configured ID.
3. Open or accept exactly one bidirectional stream; reject unexpected stream shapes and extra streams.
4. Run OTP's unmodified packet-two distribution handshake on that stream.
5. Restrict the claimed node name to the configured exact name and endpoint-ID binding.
6. Retain the normal Erlang cookie challenge and negotiated distribution flags.
7. Switch to packet-four controller framing after `f_handshake_complete`.
8. Close the complete QUIC connection when the distribution link ends.

Security is layered:

- Iroh provides encrypted transport and endpoint-key authentication.
- Static admission determines which endpoint IDs may reach the OTP handshake.
- Exact identity binding prevents one admitted endpoint from claiming another configured node name.
- Erlang cookies remain required for cluster authorization.
- Relay tokens govern relay access but do not replace endpoint admission or cookies.

Logs, errors, telemetry, crash reports, status output, and fixtures must not disclose secret keys, cookies, relay tokens, payloads, or raw distribution packets.

## 5. Runtime and Memory Invariants

1. No Iroh bind, dial, accept, stream read/write, or close waits inside a NIF on a normal BEAM scheduler.
2. Handshake waits occur in dedicated setup processes and remain cancellable by OTP's setup timer.
3. After handshake, there is at most one native read and one native write in flight per distribution stream.
4. The output controller pulls another emulator packet only after capacity is available; it never creates an unbounded Erlang or native write queue.
5. The input parser has a configured maximum frame and receive-chunk size, handles split/coalesced headers and bodies, and never allocates from an unchecked peer length.
6. Distribution writes accept iodata/iovecs without flattening on a normal scheduler; unavoidable copies are measured and bounded by one negotiated distribution packet.
7. Controller, stream, connection, endpoint, accept, and native-operation ownership is linked and deterministic. Garbage collection is only a final safety net.
8. EOF, QUIC reset, endpoint loss, owner death, or malformed framing promptly produces `nodedown` and unblocks links, monitors, and waiters.
9. Tick traffic survives idle direct and relay links; stalled peers are detected according to OTP tick settings.
10. Simultaneous connections converge through OTP's existing handshake rules and leave one live controller/resource set.
11. Unknown endpoint IDs are rejected before handshake; mismatched node-name/endpoint-ID pairs never emit `nodeup`.
12. Distribution internals cannot exhaust the atom table from peer-provided names.

## 6. Public Surface

New public module:

- `IrohBeam.Distribution`
  - `start/1` starts dynamic distribution after validating and installing configuration.
  - `stop/0` stops only dynamically started distribution through OTP's supported API.
  - `status/0` reports safe local endpoint/node/lifecycle information.
  - `peer_info/1` reports safe configured identity, connection path, and bounded counters for an exact configured node.

Internal modules use Erlang where early boot, kernel records, or distribution-controller BIFs make Erlang the direct and maintainable choice. Expected internal responsibilities are:

- `iroh_dist`: OTP alternative carrier callbacks and handshake setup.
- `iroh_dist_endpoint`: early endpoint ownership, accept loop, dialing, and registry.
- `iroh_dist_controller`: handshake-to-data-plane transition, framing, ticks, and cleanup.
- `iroh_dist_config`: validated immutable configuration and exact peer resolution.

Names may change only if the implementing epic documents a simpler ownership model. Internal modules are not public compatibility commitments.

Existing endpoint/connection/stream APIs remain source compatible. README language changes from “not Erlang distribution” to “general transport plus an explicit optional distribution carrier”; IrohBeam still does not provide membership, topology management, service discovery, or automatic clustering.

## 7. In Scope

- OTP 29 alternative distribution callbacks and process-based distribution controllers.
- Dynamic and correctly sequenced early-boot startup.
- Static exact node-to-ID/address/ticket discovery.
- Pre-handshake endpoint admission and pre-nodeup node-name/identity binding.
- Standard OTP handshake, cookies, flags, terms, links, monitors, RPC, ticks, and node lifecycle over Iroh.
- Direct, custom-relay, and forced relay-only links between separate OS processes and BEAM VMs.
- Bounded framing, backpressure, cancellation, resource cleanup, safe observability, docs, and release packaging.
- `0.2.0` precompiled NIF refresh for the existing seven targets and no-Rust consumer verification on OTP 29.

## 8. Explicitly Deferred

- Dynamic discovery/registration, an `iroh_epmd` module, DNS/Pkarr node registry, gossip membership, and automatic endpoint publication.
- A `libcluster` strategy or any component that decides desired cluster topology.
- Endpoint IDs encoded in node names as a supported zero-configuration mode.
- Wildcard admission, trust-on-first-use, certificate authorities, or group private keys.
- TCP distribution tunneling, EPMD proxying, or a sidecar carrier.
- Reimplementation of Erlang cookies, handshakes, term encoding, links, monitors, or RPC in Rust.
- Multiple Iroh distribution endpoints or multiple distribution identities in one VM.
- QUIC connection pooling or multiple Erlang node links multiplexed over one QUIC connection.
- Dynamic peer-table mutation while distribution is running.
- OTP 28 or earlier compatibility without a dedicated compatibility roadmap and CI matrix.
- WAN partition-healing policy, global process registry semantics, leader election, deployment orchestration, or relay high availability.

## 9. Epic Sequence

### Epic 1 — OTP 29 Carrier Foundation and Compatibility Gate

Establish the ADR, OTP 29 guard, Erlang carrier module boundary, callback conformance tests, package support for Erlang sources, and an expanded QA gate without changing live distribution behavior.

### Epic 2 — Distribution Endpoint, Configuration, and Static Admission

Create the dedicated early endpoint service, one immutable configuration schema, dynamic/early startup paths, exact peer resolution, endpoint-ID allowlisting, and deterministic native resource ownership.

### Epic 3 — Standard OTP Handshake and Direct Node Connectivity

Carry packet-two handshakes over one authenticated bidirectional Iroh stream, bind claimed node names to endpoint IDs, eliminate EPMD, and prove `Node.connect/1`, node-up/listing, and cookie behavior between separate direct-mode VMs.

### Epic 4 — Bounded Distribution Data Plane

Install OTP process distribution controllers, packet-four input/output framing, flow control, ticks, stats, limits, and cleanup; prove RPC, large terms, concurrent traffic, and idle links without scheduler stalls or unbounded queues.

### Epic 5 — OTP Semantics, Failure Recovery, and Observability

Prove links, monitors, exits, simultaneous connects, netsplits, reconnection, malformed-peer handling, stop/restart behavior, resource plateaus, status, telemetry, and redaction.

### Epic 6 — Forced Relay-Only Multi-BEAM Cluster Proof

Run three distinct identities in separate OS processes through the pinned local relay with direct IP disabled, proving standard OTP operations, failure/recovery, and an honest two-machine workflow with no EPMD or hidden TCP carrier.

### Epic 7 — Documentation, Packaging, and `0.2.0` Release

Freeze compatibility and public contracts, update all docs and examples, audit packages, build/publish the seven NIF targets, generate checksums from published assets, verify no-Rust OTP 29 consumers, publish Hex/docs, and monitor final CI.

## 10. Dependency Order

```text
Epic 1: carrier contract + OTP 29 gate
   -> Epic 2: endpoint + config + admission
   -> Epic 3: OTP handshake + direct Node.connect
   -> Epic 4: controller data plane + backpressure
   -> Epic 5: semantics + failures + observability
   -> Epic 6: relay-only multi-BEAM proof
   -> Epic 7: docs + package + 0.2.0 release
```

No later epic may compensate for an unverified earlier invariant. In particular, relay tests do not begin before direct distribution semantics and lifecycle tests are green.

## 11. Quality, Phase, and Commit Policy

`bin/qa_check.sh` remains the authoritative gate. It must grow to include:

- locked Elixir/Erlang and Rust build checks, formatting, warnings-as-errors, ExUnit, EUnit where used, docs, and package audit;
- an explicit OTP `29.x` compatibility assertion and compile/startup failure tests for unsupported versions where practical;
- callback contract, direct separate-VM distribution, malformed framing, cookie, identity-binding, scheduler, memory, and resource tests;
- pinned local relay readiness and forced relay-only three-VM tests;
- Rust format/check/Clippy/test and crates.io-only dependency verification;
- precompiled archive, checksum, and no-Rust consumer checks for the release.

Each epic has seven ordered phases. A phase checkbox is checked only after its code, tests, and phase exit criteria pass. After every epic:

1. run `bin/qa_check.sh` and fix every failure;
2. verify every acceptance criterion and non-goal;
3. inspect the diff for credentials, generated junk, stale claims, and unrelated cleanup;
4. update only evidence-backed checkboxes;
5. commit as `roadmap002 - epic N - <outcome>` with a concise result and verification body.

Do not stop between routine phases or epics. Release phases remain unchecked until remote artifacts, digests, consumers, Hex/HexDocs, and final CI are actually verified.

## 12. Definition of Success

ROADMAP002 is complete when three separate OTP 29 VMs, each with a distinct Iroh identity and exact static peer configuration, can form ordinary Erlang distribution links over direct or forced private-relay Iroh paths and use `Node`, RPC, links, monitors, ticks, and node lifecycle semantics without EPMD, a TCP tunnel, or reimplemented OTP semantics.

The proof must include bounded flow control, large and concurrent traffic, unknown-key and wrong-cookie rejection, node-name/identity mismatch rejection, simultaneous connects, idle ticks, netsplits, reconnection, relay interruption, deterministic cleanup, scheduler responsiveness, resource plateaus, no secret leakage, precompiled no-Rust consumers, and a fully verified `0.2.0` release.
