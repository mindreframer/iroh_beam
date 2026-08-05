# EPIC003 Spec: Standard OTP Handshake and Direct Node Connectivity

## Purpose

Connect the authenticated Iroh stream to OTP's unchanged distribution handshake and prove the first real `Node.connect/1` over direct Iroh transport without EPMD or a TCP tunnel.

## Reference Inputs

- `@meta/@pm/ROADMAP002.md`
- EPIC001 callback/OTP 29 contract
- EPIC002 endpoint, static peer, admission, and startup implementation
- OTP 29 `dist_util.hrl`, `dist_util`, `inet_tcp_dist`, and process-controller handshake examples

## Scope

In scope:

- bounded source/target node-name preface that enforces the authenticated static binding before OTP sees peer text
- packet-two handshake send/receive adapter over an Iroh bidirectional stream
- outgoing `setup/5` and incoming `accept/1`/`accept_connection/5` integration
- complete OTP `#hs_data{}` callbacks and setup-timer cancellation
- exact configured node-name restriction before atom creation
- authenticated endpoint-ID to claimed node-name binding before `nodeup`
- Erlang cookie challenge, distribution flag negotiation, creation, and simultaneous-handshake status delegated to `dist_util`
- direct separate-VM tests for connect, node-up/listing, cookie rejection, and identity mismatch
- explicit proof that EPMD and TCP distribution are absent

Out of scope:

- post-handshake distribution-controller input/output; ping, RPC, and application messages begin in Epic 4
- large terms, sustained RPC, links/monitors, tick endurance, or full failure recovery
- relay transport

## Handshake Adapter Contract

Before node-up, OTP calls carrier functions equivalent to `gen_tcp:send/2` and `gen_tcp:recv/3` with packet-two semantics. The adapter:

- prefixes each handshake payload with a two-byte big-endian length;
- rejects payloads at or above 65,536 bytes;
- reads exactly one frame while preserving any coalesced bytes for the post-handshake transition;
- accepts iodata without flattening on a normal scheduler;
- performs network work asynchronously and lets the dedicated setup process wait for reference-tagged completion;
- maps EOF, reset, timeout, malformed length, and cancellation to stable carrier shutdown reasons.

`dist_util:start_timer/1` remains authoritative for setup timeout. Killing the setup process must cancel native dial/read/write work through resource ownership and monitoring.

## Incoming Name and Identity Safety

Before `dist_util`, the bounded carrier preface compares source and target name binaries with the exact configured atoms by converting only local atoms to text; it never atomizes peer text. It acknowledges only when the authenticated endpoint ID belongs to that source name and the target is this node.

The incoming `#hs_data.allowed` list is also the exact set of configured remote node names, never the permissive empty list. OTP's `dist_util` therefore compares remote name text against pre-existing configured atoms before converting it to an atom.

After the remote name is known and before `nodeup`, the carrier verifies that the stream's authenticated Iroh endpoint ID equals the ID configured for that exact node. A mismatch closes the stream/connection and produces no `nodeup`. Outgoing setup already binds the requested configured node to the dialed endpoint ID.

No wildcard names, unconfigured node names, duplicate endpoint assignments, or dynamic node naming are accepted in this release.

## Carrier Flow

Outgoing:

1. `select/1` returns true only for an exact configured peer.
2. `setup/5` spawns a high-priority setup process using OTP's ticker spawn options.
3. The process asks the endpoint worker to dial/open the stream and verifies peer ID.
4. It builds `#hs_data{}` and calls `dist_util:handshake_we_started/1`.

Incoming:

1. The endpoint accept loop hands one admitted stream to the carrier accept loop.
2. The accept loop notifies `net_kernel` with the Iroh address/family/protocol record.
3. After controller ownership is assigned, `accept_connection/5` builds exact allowed names and `#hs_data{}`.
4. It calls `dist_util:handshake_other_started/1`.

`f_getll` returns the linked process controller PID prepared for Epic 4. The `f_address` callback, which OTP invokes after the remote name is known but before `mark_nodeup`, performs the identity/name check. `f_handshake_complete` then activates a linked, minimal bounded holding controller and returns; the full data plane replaces that holder in Epic 4.

## Acceptance Criteria

- Two direct-mode OTP 29 child VMs with distinct Iroh identities and reciprocal static configuration complete `Node.connect/1`.
- `Node.list/0` and node-up observation show the configured peer; ping, RPC, and application traffic remain explicitly gated on Epic 4's data plane.
- Both ends report the configured authenticated endpoint ID and an Iroh direct path.
- A wrong cookie reaches OTP's normal cookie rejection and never emits `nodeup`.
- An unknown endpoint ID is rejected before handshake; a configured ID claiming another node is rejected before `nodeup`.
- An unconfigured outgoing node makes `select/1`/connect fail without dialing or creating an atom from remote text.
- Handshake timeout, setup-process death, malformed packet-two input, EOF, and simultaneous initiation terminate within bounds and release resources.
- The child nodes start no EPMD child, register no EPMD names, and have no TCP listener, localhost tunnel, or copied handshake implementation.
- Full QA passes.

## Test Strategy

- Unit tests for packet-two encode/decode across split/coalesced chunks and all length/error boundaries.
- Direct child-VM node-up/listing scenarios driven by the non-distributed harness from Epic 1.
- Instrumented phase markers proving unknown ID rejection precedes `dist_util`, and name/ID mismatch precedes node-up.
- Wrong-cookie tests capture sanitized failure without asserting unstable OTP log prose.
- Atom-count/known-atom checks around repeated malicious unconfigured node-name attempts.
- Setup cancellation at dial, stream open, first send, first receive, and handshake-complete barriers.
- OS inspection for EPMD/TCP listener absence and native path inspection for direct Iroh transport.

## Quality Bar

- Handshake bytes remain opaque to Rust; no cookie or distribution-term parsing is added natively.
- OTP headers/records are used directly and only under the OTP 29 support guard.
- Setup processes use OTP-recommended spawn options and never block a scheduler in a NIF.
- Errors include operation/node context but no cookie, secret, ticket, token, payload, or raw frame.
- The minimal post-handshake holder is explicitly temporary, bounded, and removed in Epic 4.
