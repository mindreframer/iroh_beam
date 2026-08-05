defmodule IrohBeam.Identity do
  @moduledoc """
  Identity construction and persistence boundary.

  Endpoint private keys, public endpoint IDs, addresses, and tickets are added
  by Epic 2. A private identity belongs to one concurrently live endpoint.
  """
end

defmodule IrohBeam.SecretKey do
  @moduledoc "Opaque private endpoint identity value."
end

defmodule IrohBeam.EndpointId do
  @moduledoc "Public, shareable endpoint identity value."
end

defmodule IrohBeam.EndpointAddr do
  @moduledoc "Endpoint identity plus explicit reachability information."
end

defmodule IrohBeam.EndpointTicket do
  @moduledoc "Standard reusable Iroh endpoint ticket value."
end
