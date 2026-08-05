# Erlang distribution over Iroh

IrohBeam can act as an opt-in OTP 29 distribution carrier. Iroh supplies an
encrypted, endpoint-key-authenticated QUIC byte stream; OTP still supplies the
normal cookie handshake, distribution encoding, RPC, links, monitors, ticks,
and node lifecycle.

The carrier is not membership. It never chooses peers or calls
`Node.connect/1`. Every permitted peer is configured exactly, and application
code decides which links to establish.

## Security layers

Keep these separate operationally:

1. Each VM owns a distinct persistent Iroh identity. Its public endpoint ID is
   safe to share; its private key is not.
2. An ID, address, or endpoint ticket supplies reachability. A relay token only
   grants access to that relay.
3. The static peer map binds one existing Erlang node atom to one authenticated
   endpoint ID. Unknown IDs and mismatched name/key claims are rejected before
   OTP receives peer-controlled node-name text.
4. Erlang cookies remain mandatory and must match.
5. Membership code explicitly calls `Node.connect/1` and handles reconnects.

## Dynamic startup

Launch the unnamed VM with the carrier selected and EPMD disabled:

```console
elixir --erl "-proto_dist iroh -no_epmd" -S mix run --no-halt
```

After runtime configuration is available:

```elixir
peer_id = IrohBeam.EndpointId.parse!(System.fetch_env!("PEER_ID"))

{:ok, _net_kernel} =
  IrohBeam.Distribution.start(
    name: :"api@east",
    name_domain: :shortnames,
    identity: {:file, "data/api.iroh"},
    network: :n0,
    peers: %{:"worker@west" => peer_id}
  )

Node.set_cookie(:replace_with_a_deployment_secret)
true = Node.connect(:"worker@west")
:pong = Node.ping(:"worker@west")
```

`-proto_dist iroh` must be present before boot even for dynamic startup, because
OTP reads protocol selection from init arguments. `-no_epmd` is required; the
carrier never starts or registers with EPMD.

`Distribution.stop/0` is supported for dynamically started distribution. Peer
configuration is immutable while running; stop fully before installing a new
map.

## Early named startup

A release can start named distribution during kernel boot:

```console
erl -pa /path/to/iroh_beam/ebin \
  -proto_dist iroh -no_epmd -sname api@east ...
```

The same keyword configuration must already exist as boot-time application
environment under `:iroh_beam, :distribution`. A generated `sys.config` works.
A configuration provider or `runtime.exs` evaluated after kernel distribution
starts is too late. Early command-line distribution cannot be stopped through
`Distribution.stop/0` when OTP rejects that operation.

## Static targets

Typed IDs, addresses, and tickets are accepted, as are explicit serialized
forms:

```elixir
peers: %{
  :"one@west" => {:id, endpoint_id_text},
  :"two@north" => {:ticket, endpoint_ticket_text},
  :"three@south" =>
    {:addr,
     %{
       endpoint_id: endpoint_id_text,
       relay_urls: ["https://relay.example/"],
       ip_addrs: []
     }}
}
```

Aliases are exact. Wildcards, allow-all admission, dynamic mutation, and
peer-supplied atom creation are not supported.

## Private relay-only distribution

```elixir
{:ok, relay} =
  IrohBeam.Relay.new("https://relay.example/", token: System.fetch_env!("RELAY_TOKEN"))

{:ok, _} =
  IrohBeam.Distribution.start(
    name: :"api@east",
    identity: {:file, "data/api.iroh"},
    network: {:custom, [relay]},
    direct_ip: false,
    peers: %{
      :"worker@west" =>
        {:addr,
         %{
           endpoint_id: System.fetch_env!("WORKER_ID"),
           relay_urls: ["https://relay.example/"],
           ip_addrs: []
         }}
    }
  )
```

`direct_ip: false` removes IP transports, rather than preferring the relay.
`peer_info/1` reports the authenticated endpoint and selected `:relay` path.
Relay-token failure occurs before Iroh connectivity; endpoint admission occurs
before the OTP handshake; cookie failure occurs in OTP.

## Limits and lifecycle

The data plane keeps one bounded read and one flow-controlled write in flight
per link. Defaults are a 64 KiB receive chunk and a 16 MiB maximum distribution
frame. Packet lengths are checked before body retention. OTP's negotiated
fragmentation normally keeps frames much smaller than the maximum.

Ticks use OTP's `net_ticktime` and `net_tickintensity`. A relay or peer outage
can produce `nodedown`; IrohBeam does not silently reconnect or heal topology.
After reachability returns, application code explicitly calls `Node.connect/1`
again. `status/0` and `peer_info/1` expose safe lifecycle, path, byte, and frame
counters without cookies, keys, tokens, tickets, or packet contents.

## Testing boundaries

The repository's relay suite starts three separate OS processes with distinct
keys, disables direct IP, forms an explicit triangle, verifies relay paths,
runs RPC/links/monitors/large traffic/ticks, stops the relay, proves new links
fail, then restarts peers and reconnects. This is a real separate-BEAM and
relay-only proof, but it does not simulate every NAT, firewall, latency profile,
physical network, or production relay topology.
