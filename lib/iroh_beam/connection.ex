defmodule IrohBeam.Connection do
  @moduledoc """
  Authenticated Iroh connection boundary.

  IrohBeam connections carry an explicit application ALPN; they are not Erlang
  distribution links. Connection behavior is intentionally deferred to Epic 4.
  """
end
