defmodule IrohBeam.Stream do
  @moduledoc """
  Bounded QUIC stream boundary.

  Stream I/O is intentionally unavailable until Epic 5. No future receive API
  will allocate without a caller-supplied positive byte limit.
  """
end
