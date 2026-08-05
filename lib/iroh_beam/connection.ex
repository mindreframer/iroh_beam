defmodule IrohBeam.Connection do
  @moduledoc """
  Mutually authenticated Iroh connection.

  Connections negotiate one explicit application ALPN and expose the remote
  key-derived endpoint identity. They are application transports, not Erlang
  distribution links.
  """

  alias IrohBeam.{EndpointAddr, EndpointId, EndpointTicket, Error, Native}

  @enforce_keys [:resource, :remote_id, :alpn, :side, :role, :stable_id, :owner]
  defstruct [:resource, :remote_id, :alpn, :side, :role, :stable_id, :owner]

  @type t :: %__MODULE__{
          resource: reference(),
          remote_id: EndpointId.t(),
          alpn: String.t(),
          side: :client | :server,
          role: :outgoing | :incoming,
          stable_id: non_neg_integer(),
          owner: pid()
        }

  @doc false
  def connect(owner, endpoint_resource, target, alpn, options, address_book) do
    with {:ok, timeout} <- timeout_option(options),
         {:ok, target} <- resolve_target(target, address_book),
         :ok <- validate_alpn(alpn) do
      operation_ref = make_ref()

      case Native.connection_connect_start(
             self(),
             owner,
             operation_ref,
             endpoint_resource,
             native_target(target),
             alpn
           ) do
        {:ok, operation} ->
          await_connection(operation_ref, operation, timeout, owner, :connection_connect)

        {:error, error} ->
          {:error, Error.from_native(error, :connection_connect)}
      end
    end
  end

  @doc false
  def accept(owner, endpoint_resource, allowlist, options) do
    with {:ok, timeout} <- timeout_option(options) do
      operation_ref = make_ref()
      {allow_all, allowed_ids} = allowlist

      case Native.connection_accept_start(
             self(),
             owner,
             operation_ref,
             endpoint_resource,
             allow_all,
             allowed_ids
           ) do
        {:ok, operation} ->
          await_connection(operation_ref, operation, timeout, owner, :connection_accept)

        {:error, error} ->
          {:error, Error.from_native(error, :connection_accept)}
      end
    end
  end

  @spec remote_id(t()) :: EndpointId.t()
  def remote_id(%__MODULE__{remote_id: remote_id}), do: remote_id

  @spec alpn(t()) :: String.t()
  def alpn(%__MODULE__{alpn: alpn}), do: alpn

  @spec side(t()) :: :client | :server
  def side(%__MODULE__{side: side}), do: side

  @spec role(t()) :: :outgoing | :incoming
  def role(%__MODULE__{role: role}), do: role

  @spec stable_id(t()) :: non_neg_integer()
  def stable_id(%__MODULE__{stable_id: stable_id}), do: stable_id

  @spec info(t()) :: {:ok, map()} | {:error, Error.t()}
  def info(%__MODULE__{} = connection) do
    case Native.connection_info(connection.resource) do
      {:ok, info} ->
        {:ok,
         %{
           remote_id: connection.remote_id,
           alpn: info.alpn,
           side: info.side,
           role: info.role,
           stable_id: info.stable_id,
           closed?: info.closed
         }}

      {:error, error} ->
        {:error, Error.from_native(error, :connection_info)}
    end
  end

  @spec path(t()) :: {:ok, map() | nil} | {:error, Error.t()}
  def path(%__MODULE__{resource: resource}) do
    case Native.connection_path(resource) do
      {:ok, path} -> {:ok, path}
      {:error, error} -> {:error, Error.from_native(error, :connection_info)}
    end
  end

  @spec close(t()) :: :ok
  def close(%__MODULE__{resource: resource}) do
    Native.connection_close(resource)
    :ok
  end

  @spec closed(t(), timeout()) :: :ok | {:error, Error.t()}
  def closed(connection, timeout \\ 5_000)

  def closed(%__MODULE__{resource: resource}, timeout)
      when is_integer(timeout) and timeout > 0 do
    case Native.connection_close_reason(resource) do
      {:ok, :closed} ->
        :ok

      {:ok, nil} ->
        operation_ref = make_ref()

        case Native.connection_closed_start(self(), operation_ref, resource) do
          {:ok, operation} ->
            case await_operation(operation_ref, operation, timeout, :connection_closed) do
              {:ok, :closed} -> :ok
              {:error, error} -> {:error, error}
            end

          {:error, error} ->
            {:error, Error.from_native(error, :connection_closed)}
        end
    end
  end

  @spec close_reason(t()) :: nil | Error.t()
  def close_reason(%__MODULE__{resource: resource}) do
    case Native.connection_close_reason(resource) do
      {:ok, nil} ->
        nil

      {:ok, :closed} ->
        %Error{
          category: :closed,
          operation: :connection,
          message: "connection is closed",
          context: %{}
        }
    end
  end

  defp await_connection(operation_ref, operation, timeout, owner, operation_name) do
    case await_operation(operation_ref, operation, timeout, operation_name) do
      {:ok, resource} ->
        case Native.connection_info(resource) do
          {:ok, info} ->
            {:ok,
             %__MODULE__{
               resource: resource,
               remote_id: EndpointId.from_canonical(info.remote_id),
               alpn: info.alpn,
               side: info.side,
               role: info.role,
               stable_id: info.stable_id,
               owner: owner
             }}

          {:error, error} ->
            Native.connection_close(resource)
            {:error, Error.from_native(error, :connection_info)}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp await_operation(operation_ref, operation, timeout, operation_name) do
    receive do
      {Native, ^operation_ref, {:ok, value}} ->
        {:ok, value}

      {Native, ^operation_ref, {:error, error}} ->
        {:error, Error.from_native(error, operation_name)}
    after
      timeout ->
        Native.operation_cancel(operation)

        {:error,
         %Error{
           category: :timeout,
           operation: operation_name,
           message: "operation timed out",
           context: %{}
         }}
    end
  end

  defp timeout_option(options) when is_list(options) do
    with true <- Keyword.keyword?(options),
         {:ok, options} <- Keyword.validate(options, timeout: 5_000),
         timeout when is_integer(timeout) and timeout > 0 <- options[:timeout] do
      {:ok, timeout}
    else
      _error -> invalid(:connection, "connection options require a positive timeout")
    end
  end

  defp timeout_option(_options), do: invalid(:connection, "connection options are invalid")

  defp validate_alpn(alpn)
       when is_binary(alpn) and byte_size(alpn) in 1..255 do
    if String.contains?(alpn, <<0>>),
      do: invalid(:connection_connect, "ALPN may not contain NUL bytes"),
      else: :ok
  end

  defp validate_alpn(_alpn), do: invalid(:connection_connect, "ALPN is invalid")

  defp resolve_target(%EndpointId{} = id, address_book) do
    {:ok, Map.get(address_book, to_string(id), id)}
  end

  defp resolve_target(%EndpointAddr{} = addr, _address_book), do: {:ok, addr}

  defp resolve_target(%EndpointTicket{} = ticket, _address_book),
    do: {:ok, EndpointTicket.endpoint_addr(ticket)}

  defp resolve_target(_target, _address_book),
    do: invalid(:connection_connect, "dial target is invalid")

  defp native_target(%EndpointId{} = id) do
    %{endpoint_id: to_string(id), relay_urls: [], ip_addrs: []}
  end

  defp native_target(%EndpointAddr{} = addr) do
    %{
      endpoint_id: to_string(addr.id),
      relay_urls: addr.relay_urls,
      ip_addrs: addr.ip_addrs
    }
  end

  defp invalid(operation, message) do
    {:error,
     %Error{category: :invalid_argument, operation: operation, message: message, context: %{}}}
  end
end

defimpl Inspect, for: IrohBeam.Connection do
  import Inspect.Algebra

  def inspect(connection, _options) do
    concat([
      "#IrohBeam.Connection<id=",
      Integer.to_string(connection.stable_id),
      " remote=",
      IrohBeam.EndpointId.short(connection.remote_id),
      " alpn=",
      inspect(connection.alpn),
      ">"
    ])
  end
end
