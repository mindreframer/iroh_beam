defmodule IrohBeam.Relay do
  @moduledoc """
  Validated, secret-safe relay configuration boundary.

  Relay access tokens are credentials, unlike endpoint tickets, and must never
  be included in inspection, errors, logs, or telemetry.
  """
end
