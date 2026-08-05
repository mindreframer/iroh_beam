# Bounded streams and datagrams

Connections multiplex unidirectional and bidirectional QUIC streams:

```elixir
{:ok, stream} = IrohBeam.Connection.open_bi(connection)
:ok = IrohBeam.Stream.send(stream, "hello", chunk_size: 64 * 1024)
:ok = IrohBeam.Stream.finish(stream)

case IrohBeam.Stream.recv(stream, 64 * 1024) do
  {:ok, bytes} -> bytes
  :eof -> :done
  {:error, error} -> {:failed, error}
end
```

A newly opened stream is lazy: the peer cannot accept it until data is sent (or
a later stream is used). `send/3` honors QUIC flow control and writes bounded
chunks without a fire-and-forget native queue. `send_chunk/3` returns the prefix
written. The caller must choose an explicit maximum for every receive.
`recv_to_end/3` exists only with a positive hard limit.

Each stream half permits one mutable operation. A competing operation on the
same half returns `:busy`; send and receive on opposite halves remain concurrent.
Timeout and caller death cancel a pending operation. A cancelled send-all may
have transmitted a prefix, as required by QUIC's cancellation semantics.

`finish` announces send EOF. `reset` abandons a send half with a QUIC code;
`stop` rejects further receive data; and `abort` applies both. Peer reset, peer
stop, or connection loss returns stable peer-abort/closed errors and wakes
pending callers. Codes must fit QUIC's 62-bit varint range.

Datagrams are unreliable and unordered. They may be lost or reordered and are
never a substitute for a stream:

```elixir
{:ok, %{max_size: max_size}} = IrohBeam.Connection.datagram_info(connection)
:ok = IrohBeam.Connection.send_datagram(connection, payload)
{:ok, payload} = IrohBeam.Connection.recv_datagram(peer_connection)
```

Oversized datagrams fail before queueing. `wait_for_capacity: true` (the default)
uses the bounded QUIC send buffer; setting it to false returns a capacity error
instead of waiting.
