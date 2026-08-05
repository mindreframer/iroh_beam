# Security and limits

Iroh authenticates every connection with endpoint keys and encrypts QUIC traffic.
Applications still decide which authenticated IDs may use each ALPN and how
payloads are framed and authorized. `peer_allowlist` is a transport admission
control, not a group-membership protocol.

Private endpoint keys are opaque and inspection-redacted. File identities are
atomically created with owner-only Unix permissions. Never reuse one key for two
live endpoints. Relay tokens are separate bearer credentials and are redacted.
Tickets are not secrets, but can reveal current IP and relay addresses.

IrohBeam bounds native work with:

- endpoint pending-accept and connection limits;
- one mutable operation per stream half;
- positive receive and read-to-end limits;
- bounded send sizes and chunks;
- QUIC flow-control and datagram capacity;
- operation, startup, shutdown, and online deadlines;
- cancellation on caller or owner death.

Distribution adds exact static node/endpoint-ID admission, a bounded name/key
preface that does not atomize peer text, the normal OTP cookie handshake, one
read/write in flight, and a maximum packet-four frame. Relay tokens, endpoint
keys, and cookies are independent credentials. Distribution does not make a
relay token or cookie a membership service, and peer-map changes require a full
restart.

A send-all timeout can leave a transmitted prefix because multi-write QUIC
operations are not cancellation-atomic. Applications needing message atomicity
must add framing and protocol-level acknowledgement.

Errors and telemetry exclude private keys, tokens, payloads, peer close text,
addresses, tickets, and unstable native chains. Avoid logging raw options or
application payloads around library calls.
