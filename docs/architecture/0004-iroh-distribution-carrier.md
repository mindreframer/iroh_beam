# ADR 0004: Direct OTP 29 distribution carrier over Iroh

## Status

Accepted for ROADMAP002.

## Context

IrohBeam 0.1 exposes authenticated QUIC transport but does not implement Erlang
distribution. Native BEAM clustering needs an OTP distribution carrier, a way
to resolve Erlang node names to Iroh endpoint identities, and lifecycle
integration early enough for `net_kernel` startup.

A TCP proxy carried over Iroh would retain EPMD and distribution-port routing,
add local sockets and copies, and split ownership across OTP, a tunnel, and
Iroh. Reimplementing the distribution handshake or term protocol in Rust would
duplicate OTP security and process semantics.

## Decision

IrohBeam implements `iroh_dist`, selected by `-proto_dist iroh`, as a direct
alternative carrier on OTP 29. One OTP distribution connection uses one
mutually authenticated Iroh QUIC connection and one bidirectional stream. A
small bounded carrier preface exchanges the configured source and target node
names as UTF-8 and is acknowledged only after both names and the authenticated
endpoint ID match static configuration. This prevents an admitted key from
reaching OTP under another configured name and prevents peer text from creating
atoms. OTP's own handshake follows unchanged.

OTP remains responsible for the distribution handshake, cookies, negotiated
flags, term encoding, links, monitors, exit signals, ticks, simultaneous
connection arbitration, and node lifecycle. Before node-up the carrier exposes
packet-two callbacks to `dist_util`; after handshake an OTP 29 process
distribution controller moves opaque packet-four frames. Rust never parses
cookies, node names, distribution controls, or Erlang terms.

Discovery is a separate exact static map from existing Erlang node atoms to
Iroh endpoint IDs, addresses, or tickets. The authenticated endpoint ID is
checked before the OTP handshake and bound to the exact configured node name
before node-up. Membership and calls to `Node.connect/1` remain application
owned.

The supported mode uses `-no_epmd`. The carrier does not register with EPMD and
does not implement a custom EPMD module. A dedicated early Erlang worker owns
the distribution endpoint because protocol children start before `net_kernel`
and may start before the normal IrohBeam application and telemetry runtime.

Version 0.2 targets OTP 29 only. The implementation uses OTP 29 kernel records
and process-controller BIFs behind one centralized support guard. Supporting an
older OTP requires separate compatibility code and CI evidence.

## Rejected alternatives

- **TCP-over-Iroh tunnel:** preserves EPMD/port concerns and adds avoidable
  sockets, copies, and failure ownership.
- **Sidecar carrier:** adds IPC, deployment, supervision, and duplicate
  buffering without helping OTP integration.
- **Custom EPMD service:** unnecessary for exact static discovery and would
  conflate registration with membership.
- **Rust distribution protocol:** duplicates sensitive OTP behavior and would
  not preserve native links, monitors, and lifecycle automatically.
- **Untested multi-OTP compatibility:** kernel carrier APIs are versioned; the
  release promises only what CI executes.

## Module responsibilities

- `iroh_dist`: OTP carrier callbacks and `dist_util` handshake setup.
- `iroh_dist_support`: the sole OTP-version guard and incarnation creation.
- `iroh_dist_config`: immutable validation and exact peer identity indexes.
- `iroh_dist_endpoint`: early endpoint, acceptance, dialing, and ownership.
- `iroh_dist_preface`: pre-handshake exact name/endpoint-ID binding without
  atom creation.
- `iroh_dist_controller`: packet framing, process-controller I/O, ticks, and
  link cleanup.
- `IrohBeam.Distribution`: optional public dynamic startup and safe status.

The latter four transport modules arrive in dependency order in ROADMAP002;
this ADR does not imply that an unimplemented phase is already supported.
