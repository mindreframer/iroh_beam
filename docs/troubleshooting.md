# Troubleshooting

## ID-only dialing returns `:resolution`

An endpoint ID has no network path. Use `:n0`, configure a static `address_book`,
or share an endpoint address or ticket. Direct/custom profiles never silently
fall back to public lookup.

## A direct endpoint is not reachable

Inspect `Endpoint.bound_sockets/1` and `Endpoint.addr/1`. Loopback addresses work
only on one host. Firewalls, NATs, and stale tickets can prevent direct paths.
Enable an appropriate relay rather than assuming a local direct test proves NAT
traversal.

## A custom endpoint never becomes online

Check relay readiness, URL, TLS policy, and bearer admission. `await_online/2`
means a relay handshake completed; it intentionally times out when a token is
wrong. Tokens are redacted, so compare deployment configuration at its source.

## A peer cannot accept an opened stream

QUIC streams are lazy. Send data on the new stream before waiting for the peer to
accept it. Check uni/bi direction and negotiated ALPN.

## `:busy` is returned

Another mutable operation owns the same stream half or configured accept/datagram
slot. Wait for, cancel, reset, or stop that operation. Opposite stream halves are
independent.

## `Distribution.start/1` rejects VM startup

Dynamic distribution requires an unnamed OTP 29 VM launched with
`-proto_dist iroh -no_epmd`. Early named startup requires the complete
`:iroh_beam, :distribution` environment in boot-time `sys.config`; a later
runtime provider cannot repair an already failed kernel distribution start.

## A configured distribution peer does not connect

Check each layer in order: Iroh relay/direct reachability, exact endpoint ID,
source/target node-name binding, and the Erlang cookie. `peer_info/1` reports the
expected authenticated ID and selected path but deliberately omits cookies and
relay tokens. Static peer changes require a full dynamic distribution restart.
After a netsplit or relay outage, explicitly call `Node.connect/1`; no membership
or automatic reconnect policy is included.

## Precompiled NIF cannot load

Verify the runtime is one of the documented targets, NIF 2.16 is supported, and
the downloaded archive matches `checksum-Elixir.IrohBeam.Native.exs`. Set
`IROH_BEAM_BUILD=1` only on a host with Rust 1.91 when intentionally building
from source.
