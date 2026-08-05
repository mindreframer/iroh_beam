# Telemetry

IrohBeam emits optional `:telemetry` events:

- `[:iroh_beam, :endpoint, :start | :close, :start | :stop | :exception]`
- `[:iroh_beam, :connection, :connect | :accept | :path, ...]`
- `[:iroh_beam, :connection, :path, :selected]`
- `[:iroh_beam, :stream, :send | :recv, :start | :stop | :exception]`
- `[:iroh_beam, :datagram, :send | :recv, :start | :stop | :exception]`
- `[:iroh_beam, :operation, :cancelled]`

Stop events include `:duration` in native monotonic time units and non-negative
`:bytes`. Metadata includes bounded atoms such as `:profile`, `:kind`, `:outcome`,
`:category`, and `:operation`.

Endpoint IDs, addresses, tickets, stable connection IDs, stream IDs, payloads,
peer close text, private keys, and relay tokens are deliberately absent. This
keeps the default contract secret-safe and avoids unbounded-cardinality labels.
Telemetry handler failures are isolated by `:telemetry` and cannot alter
transport results.

```elixir
:telemetry.attach(
  "iroh-beam-send",
  [:iroh_beam, :stream, :send, :stop],
  fn _event, measurements, metadata, _config ->
    Logger.info("Iroh send", duration: measurements.duration, outcome: metadata.outcome)
  end,
  nil
)
```
