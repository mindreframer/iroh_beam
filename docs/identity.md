# Identity, addresses, and tickets

Every live Iroh endpoint has a distinct private `IrohBeam.SecretKey`. Its public
`IrohBeam.EndpointId` is the authenticated identity peers dial.

```elixir
{:ok, secret_key} = IrohBeam.SecretKey.load_or_create("data/endpoint.identity")
{:ok, endpoint_id} = IrohBeam.SecretKey.endpoint_id(secret_key)
IO.puts(endpoint_id)
```

`SecretKey` inspection is always redacted. Only `SecretKey.export/1` returns the
32 private bytes. File-backed identity uses atomic create-if-absent publication,
owner-only mode on Unix, and strict 32-byte loading. Corrupt files fail and are
not silently replaced. Do not point concurrently live endpoints at the same
identity file: that creates an identity collision, not a cluster.

An endpoint ID is public but contains no reachability data. An `EndpointAddr`
adds current relay URLs and direct socket addresses:

```elixir
{:ok, addr} =
  IrohBeam.EndpointAddr.new(endpoint_id,
    relay_urls: ["https://relay.example.com./"],
    ip_addrs: ["192.0.2.10:443", "[2001:db8::10]:443"]
  )
```

An `IrohBeam.EndpointTicket` uses the standard `iroh-tickets` wire and text
format. It is reusable rather than one-time and is not a private credential, but
it can disclose current relay and IP addresses and can become stale.

```elixir
{:ok, ticket} = IrohBeam.EndpointTicket.new(addr)
shared_text = to_string(ticket)
{:ok, same_ticket} = IrohBeam.EndpointTicket.parse(shared_text)
```

A relay access token has a different role: it authorizes use of a private relay.
It is a credential and must be redacted. Sharing one relay policy never changes
the requirement that endpoints use distinct private identities.
