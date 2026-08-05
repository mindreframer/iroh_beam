# ADR 0001: Embed Iroh in the BEAM

## Status

Accepted for ROADMAP001.

## Decision

IrohBeam embeds Iroh through Rustler. It does not start or supervise a sidecar.
Iroh is designed as a Rust library, and embedding avoids an additional process,
IPC protocol, buffering layer, deployment artifact, and failure protocol.

A sidecar may be evaluated later only if measured fault-containment needs justify
that cost. Erlang distribution, EPMD replacement, clustering, membership, RPC,
and application framing are not part of this transport.

## Consequences

The NIF boundary is deliberately conservative: entry points validate and submit
work only; async work runs on one managed Tokio runtime; callers receive exactly
one reference-tagged terminal result; caller death, timeout, and explicit cancel
abort pending work; and recoverable panics become stable errors. Explicit close
will be the deterministic resource path. Garbage collection remains a final
safety net and destructors never block.
