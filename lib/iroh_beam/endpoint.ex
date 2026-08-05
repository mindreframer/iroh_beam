defmodule IrohBeam.Endpoint do
  @moduledoc """
  Supervised endpoint lifecycle boundary.

  Endpoints are OTP children rather than VM-global singletons. Network behavior
  is intentionally unavailable until Epic 3.
  """
end
