# EPIC002 Spec: Identity, Addresses, and Tickets

## Purpose

Provide safe, interoperable identity and dialing values so endpoint identity can persist while IP and relay details may change.

## Reference Inputs

- `@meta/@pm/ROADMAP001.md`
- EPIC001 native boundary and QA contract
- Iroh `SecretKey`, `EndpointId`, `EndpointAddr`, and `iroh-tickets::endpoint::EndpointTicket`

## Scope

In scope:

- opaque secret-key generation/import/export and public endpoint-ID derivation
- endpoint-ID parsing, formatting, bytes, equality, hashing, and short display
- endpoint addresses containing an ID, relay URLs, and direct socket addresses
- standard endpoint-ticket encode/decode through `iroh-tickets`
- atomic optional file-backed identity creation/loading with restrictive permissions where supported
- stable validation/errors and redacted inspection
- documentation for ID, address, ticket, relay token, and private-key roles

Out of scope:

- endpoint bind or network access
- address lookup, ticket refresh, key escrow, key rotation, HSMs, or OS keychains
- application membership/group-key protocols

## Identity Contract

A `SecretKey` is private endpoint identity and is redacted by default. Its public `EndpointId` is safe to share and is the authenticated identity peers dial. Every concurrent endpoint requires a distinct private key. IrohBeam does not describe copying one secret key to multiple live endpoints as clustering.

File-backed identity uses create-if-absent semantics, atomic publication, exact format validation, and owner-only permissions when the platform supports them. It never replaces a valid existing key and never logs key material. Applications that need a key manager can pass raw/opaque identity instead.

An `EndpointAddr` bundles identity with current relay/direct addresses. An `EndpointTicket` is the standard reusable Iroh ticket and may expose IP addresses; it is not a secret or a one-time token. The wrapper invents no incompatible ticket format.

## Acceptance Criteria

- Generated keys are valid, independent, and derive stable endpoint IDs.
- Text/byte endpoint-ID forms round-trip against upstream Iroh test vectors.
- Endpoint addresses validate and normalize IPv4, IPv6, relay, duplicate, and ordering cases.
- Standard tickets round-trip between IrohBeam and upstream Iroh.
- Concurrent `load_or_create` calls publish one complete identity, and restart loading preserves the ID.
- Corrupt files fail without replacement; private bytes and tokens appear nowhere observable.
- Documentation explicitly distinguishes endpoint private keys, endpoint IDs, tickets, and shared relay tokens.

## Test Strategy

- Use fixed upstream-compatible identity/address/ticket vectors and generated round trips.
- Race file creation with explicit barriers in unique temporary directories.
- Cover permissions, Unicode paths, malformed/truncated data, existing files, and cleanup.
- Scan `Inspect`, errors, logs, and captured test output for known secret fixtures.
- Property-test bounded parsing inputs where the existing dependency/tooling permits without adding a speculative framework.

## Quality Bar

- Secret values are opaque and redacted; only explicit export returns private bytes.
- File persistence is complete-or-absent and does not silently regenerate on corruption.
- Public representations are interoperable, not package-specific.
- Pure value operations do not start the native runtime unnecessarily beyond loading the NIF.
- Full QA is green before commit.
