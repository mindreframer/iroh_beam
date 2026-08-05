defmodule IrohBeam.Identity do
  @moduledoc """
  Endpoint identity generation and optional file-backed persistence.

  A private identity belongs to exactly one concurrently live endpoint. Share
  its public `IrohBeam.EndpointId`, an `IrohBeam.EndpointAddr`, or an
  `IrohBeam.EndpointTicket` with peers; do not copy one private key into several
  live endpoints as a clustering mechanism.

  Identity files contain exactly the 32 private key bytes. Creation uses a
  restrictive temporary file and atomic create-if-absent publication. A corrupt
  existing file returns an error and is never replaced.
  """

  alias IrohBeam.SecretKey

  @spec generate() :: {:ok, SecretKey.t()} | {:error, IrohBeam.Error.t()}
  defdelegate generate(), to: SecretKey

  @spec load_or_create(Path.t()) :: {:ok, SecretKey.t()} | {:error, IrohBeam.Error.t()}
  defdelegate load_or_create(path), to: SecretKey
end

defmodule IrohBeam.SecretKey do
  @moduledoc """
  Opaque private endpoint identity.

  Inspection is always redacted. `export/1` is the only API that returns the 32
  private bytes and should be used only for explicit key-manager integration.
  """

  alias IrohBeam.{EndpointId, Error, Native}

  @enforce_keys [:resource]
  defstruct [:resource]

  @opaque t :: %__MODULE__{resource: reference()}

  @spec generate() :: {:ok, t()} | {:error, Error.t()}
  def generate do
    Native.identity_generate()
    |> wrap(:identity_generate)
  end

  @spec from_bytes(binary()) :: {:ok, t()} | {:error, Error.t()}
  def from_bytes(bytes) when is_binary(bytes) do
    Native.secret_key_import(bytes)
    |> wrap(:secret_key_import)
  end

  def from_bytes(_bytes), do: invalid(:secret_key_import, "secret key bytes must be a binary")

  @spec export(t()) :: {:ok, binary()} | {:error, Error.t()}
  def export(%__MODULE__{resource: resource}) do
    Native.secret_key_export(resource)
    |> translate(:secret_key_export)
  end

  @spec endpoint_id(t()) :: {:ok, EndpointId.t()} | {:error, Error.t()}
  def endpoint_id(%__MODULE__{resource: resource}) do
    case Native.secret_key_endpoint_id(resource) do
      {:ok, text} -> {:ok, EndpointId.from_canonical(text)}
      {:error, error} -> {:error, Error.from_native(error, :endpoint_id)}
    end
  end

  @spec load_or_create(Path.t()) :: {:ok, t()} | {:error, Error.t()}
  def load_or_create(path) when is_binary(path) do
    Native.identity_load_or_create(Path.expand(path))
    |> wrap(:identity_load)
  end

  def load_or_create(_path), do: invalid(:identity_load, "identity path must be a string")

  defp wrap({:ok, resource}, _operation), do: {:ok, %__MODULE__{resource: resource}}
  defp wrap({:error, error}, operation), do: {:error, Error.from_native(error, operation)}

  defp translate({:ok, value}, _operation), do: {:ok, value}
  defp translate({:error, error}, operation), do: {:error, Error.from_native(error, operation)}

  defp invalid(operation, message) do
    {:error,
     %Error{category: :invalid_argument, operation: operation, message: message, context: %{}}}
  end
end

defimpl Inspect, for: IrohBeam.SecretKey do
  def inspect(_secret_key, _options), do: "#IrohBeam.SecretKey<redacted>"
end

defmodule IrohBeam.EndpointId do
  @moduledoc """
  Public, shareable endpoint identity derived from a private key.

  The canonical string form is the lowercase 64-character Iroh hex encoding.
  Parsing also accepts upstream-compatible base32 forms.
  """

  alias IrohBeam.{Error, Native}

  @enforce_keys [:bytes, :text]
  defstruct [:bytes, :text]

  @type t :: %__MODULE__{bytes: <<_::256>>, text: String.t()}

  @spec parse(String.t()) :: {:ok, t()} | {:error, Error.t()}
  def parse(text) when is_binary(text) do
    case Native.endpoint_id_parse(text) do
      {:ok, canonical} -> {:ok, from_canonical(canonical)}
      {:error, error} -> {:error, Error.from_native(error, :endpoint_id)}
    end
  end

  def parse(_text), do: invalid("endpoint ID must be a string")

  @spec parse!(String.t()) :: t()
  def parse!(text) do
    case parse(text) do
      {:ok, endpoint_id} -> endpoint_id
      {:error, error} -> raise error
    end
  end

  @spec from_bytes(binary()) :: {:ok, t()} | {:error, Error.t()}
  def from_bytes(bytes) when is_binary(bytes) do
    case Native.endpoint_id_from_bytes(bytes) do
      {:ok, canonical} -> {:ok, from_canonical(canonical)}
      {:error, error} -> {:error, Error.from_native(error, :endpoint_id)}
    end
  end

  def from_bytes(_bytes), do: invalid("endpoint ID bytes must be a binary")

  @doc false
  @spec from_canonical(String.t()) :: t()
  def from_canonical(text) do
    %__MODULE__{bytes: Base.decode16!(text, case: :mixed), text: text}
  end

  @spec to_bytes(t()) :: binary()
  def to_bytes(%__MODULE__{bytes: bytes}), do: bytes

  @spec short(t()) :: String.t()
  def short(%__MODULE__{text: text}), do: binary_part(text, 0, 10)

  defp invalid(message) do
    {:error,
     %Error{category: :invalid_argument, operation: :endpoint_id, message: message, context: %{}}}
  end
end

defimpl String.Chars, for: IrohBeam.EndpointId do
  def to_string(%{text: text}), do: text
end

defimpl Inspect, for: IrohBeam.EndpointId do
  import Inspect.Algebra
  def inspect(endpoint_id, _options), do: concat(["#IrohBeam.EndpointId<", endpoint_id.text, ">"])
end

defmodule IrohBeam.EndpointAddr do
  @moduledoc """
  Endpoint identity plus current relay and direct socket addresses.

  Duplicate addresses are removed and all values use upstream Iroh ordering and
  normalization. An address containing only an endpoint ID still requires an
  address-lookup source when it is dialed.
  """

  alias IrohBeam.{EndpointId, Error, Native}

  @enforce_keys [:id, :relay_urls, :ip_addrs]
  defstruct [:id, :relay_urls, :ip_addrs]

  @type t :: %__MODULE__{
          id: EndpointId.t(),
          relay_urls: [String.t()],
          ip_addrs: [String.t()]
        }

  @spec new(EndpointId.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(id, options \\ [])

  def new(%EndpointId{} = id, options) when is_list(options) do
    with {:ok, options} <- Keyword.validate(options, relay_urls: [], ip_addrs: []),
         relay_urls when is_list(relay_urls) <- options[:relay_urls],
         ip_addrs when is_list(ip_addrs) <- options[:ip_addrs],
         true <- Enum.all?(relay_urls, &is_binary/1) and Enum.all?(ip_addrs, &is_binary/1) do
      case Native.endpoint_addr_normalize(EndpointId.to_bytes(id), relay_urls, ip_addrs) do
        {:ok, normalized} ->
          {:ok,
           %__MODULE__{
             id: id,
             relay_urls: normalized.relay_urls,
             ip_addrs: normalized.ip_addrs
           }}

        {:error, error} ->
          {:error, Error.from_native(error, :endpoint_addr)}
      end
    else
      {:error, _unknown} -> invalid("endpoint address options are invalid")
      _other -> invalid("relay_urls and ip_addrs must be lists of strings")
    end
  end

  def new(_id, _options), do: invalid("endpoint address requires an EndpointId")

  @doc false
  def from_normalized(id, relay_urls, ip_addrs) do
    %__MODULE__{id: id, relay_urls: relay_urls, ip_addrs: ip_addrs}
  end

  defp invalid(message) do
    {:error,
     %Error{
       category: :invalid_argument,
       operation: :endpoint_addr,
       message: message,
       context: %{}
     }}
  end
end

defmodule IrohBeam.EndpointTicket do
  @moduledoc """
  Standard reusable Iroh endpoint ticket.

  Tickets contain an endpoint ID and current reachability hints. They are not
  private credentials or one-time tokens, but may disclose relay and IP
  addresses. Stale tickets can stop being useful as network paths change.
  """

  alias IrohBeam.{EndpointAddr, EndpointId, Error, Native}

  @enforce_keys [:addr, :text, :bytes]
  defstruct [:addr, :text, :bytes]

  @type t :: %__MODULE__{addr: EndpointAddr.t(), text: String.t(), bytes: binary()}

  @spec new(EndpointAddr.t()) :: {:ok, t()} | {:error, Error.t()}
  def new(%EndpointAddr{} = addr) do
    id = EndpointId.to_bytes(addr.id)

    with {:ok, text} <-
           Native.endpoint_ticket_from_addr_text(id, addr.relay_urls, addr.ip_addrs)
           |> translate(:endpoint_ticket),
         {:ok, bytes} <-
           Native.endpoint_ticket_from_addr_bytes(id, addr.relay_urls, addr.ip_addrs)
           |> translate(:endpoint_ticket) do
      {:ok, %__MODULE__{addr: addr, text: text, bytes: bytes}}
    end
  end

  def new(_addr), do: invalid("endpoint ticket requires an EndpointAddr")

  @spec parse(String.t()) :: {:ok, t()} | {:error, Error.t()}
  def parse(text) when is_binary(text) do
    with {:ok, parsed} <- Native.endpoint_ticket_parse_text(text) |> translate(:endpoint_ticket),
         {:ok, bytes} <-
           Native.endpoint_ticket_text_to_bytes(parsed.text) |> translate(:endpoint_ticket) do
      from_parsed(parsed, bytes)
    end
  end

  def parse(_text), do: invalid("endpoint ticket must be a string")

  @spec parse!(String.t()) :: t()
  def parse!(text) do
    case parse(text) do
      {:ok, ticket} -> ticket
      {:error, error} -> raise error
    end
  end

  @spec from_bytes(binary()) :: {:ok, t()} | {:error, Error.t()}
  def from_bytes(bytes) when is_binary(bytes) do
    with {:ok, parsed} <-
           Native.endpoint_ticket_parse_bytes(bytes) |> translate(:endpoint_ticket),
         {:ok, canonical_bytes} <-
           Native.endpoint_ticket_text_to_bytes(parsed.text) |> translate(:endpoint_ticket) do
      from_parsed(parsed, canonical_bytes)
    end
  end

  def from_bytes(_bytes), do: invalid("endpoint ticket bytes must be a binary")

  @spec to_bytes(t()) :: binary()
  def to_bytes(%__MODULE__{bytes: bytes}), do: bytes

  @spec endpoint_addr(t()) :: EndpointAddr.t()
  def endpoint_addr(%__MODULE__{addr: addr}), do: addr

  defp from_parsed(parsed, bytes) do
    id = EndpointId.from_canonical(parsed.endpoint_id)
    addr = EndpointAddr.from_normalized(id, parsed.relay_urls, parsed.ip_addrs)
    {:ok, %__MODULE__{addr: addr, text: parsed.text, bytes: bytes}}
  end

  defp translate({:ok, value}, _operation), do: {:ok, value}
  defp translate({:error, error}, operation), do: {:error, Error.from_native(error, operation)}

  defp invalid(message) do
    {:error,
     %Error{
       category: :invalid_argument,
       operation: :endpoint_ticket,
       message: message,
       context: %{}
     }}
  end
end

defimpl String.Chars, for: IrohBeam.EndpointTicket do
  def to_string(%{text: text}), do: text
end

defimpl Inspect, for: IrohBeam.EndpointTicket do
  import Inspect.Algebra

  def inspect(ticket, _options) do
    concat([
      "#IrohBeam.EndpointTicket<id=",
      IrohBeam.EndpointId.short(ticket.addr.id),
      " relays=",
      Integer.to_string(length(ticket.addr.relay_urls)),
      " ips=",
      Integer.to_string(length(ticket.addr.ip_addrs)),
      ">"
    ])
  end
end
