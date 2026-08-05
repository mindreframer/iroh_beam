defmodule IrohBeam.Endpoint do
  @moduledoc """
  Supervised ownership and lifecycle for one embedded Iroh endpoint.

  Each endpoint is an OTP process with its own private identity and native
  resource. `:direct` uses no relay or address-lookup infrastructure; `:n0`
  uses Iroh's public defaults; `:no_relay` keeps n0 address lookup but disables
  relays; and `{:custom, relays}` uses only the supplied relay records.
  """

  use GenServer

  alias IrohBeam.{Connection, EndpointAddr, EndpointId, Error, Native, Relay, SecretKey}

  @default_startup_timeout 10_000
  @default_shutdown_timeout 5_000

  @type server :: GenServer.server()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    with {:ok, config} <- validate_options(options) do
      case GenServer.start(__MODULE__, config, name_option(config.name)) do
        {:ok, endpoint} ->
          try do
            Process.link(endpoint)
            {:ok, endpoint}
          rescue
            ArgumentError -> invalid(:endpoint_start, "endpoint exited during startup")
          end

        {:error, %Error{} = error} ->
          {:error, error}

        other ->
          other
      end
    end
  end

  def start_link(_options),
    do: invalid(:endpoint_start, "endpoint options must be a keyword list")

  def child_spec(options) do
    %{
      id: Keyword.get(options, :id, {__MODULE__, System.unique_integer([:positive, :monotonic])}),
      start: {__MODULE__, :start_link, [Keyword.delete(options, :id)]},
      restart: :transient,
      type: :worker
    }
  end

  @spec close(server()) :: :ok | {:error, Error.t()}
  def close(endpoint), do: GenServer.call(endpoint, :close, :infinity)

  @spec close(server(), timeout()) :: :ok | {:error, Error.t()}
  def close(endpoint, timeout) when is_integer(timeout) and timeout > 0 do
    GenServer.call(endpoint, {:close, timeout}, timeout + 1_000)
  end

  @spec status(server()) :: {:ok, map()} | {:error, Error.t()}
  def status(endpoint), do: GenServer.call(endpoint, :status)

  @spec id(server()) :: {:ok, EndpointId.t()} | {:error, Error.t()}
  def id(endpoint), do: GenServer.call(endpoint, :id)

  @spec addr(server()) :: {:ok, EndpointAddr.t()} | {:error, Error.t()}
  def addr(endpoint), do: GenServer.call(endpoint, :addr)

  @spec bound_sockets(server()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def bound_sockets(endpoint), do: GenServer.call(endpoint, :bound_sockets)

  @spec online?(server()) :: boolean()
  def online?(endpoint), do: GenServer.call(endpoint, :online?)

  @spec connect(
          server(),
          EndpointId.t() | EndpointAddr.t() | IrohBeam.EndpointTicket.t(),
          binary(),
          keyword()
        ) ::
          {:ok, Connection.t()} | {:error, Error.t()}
  def connect(endpoint, target, alpn, options \\ []) do
    with {:ok, config} <- connection_config(endpoint) do
      Connection.connect(
        config.owner,
        config.resource,
        target,
        alpn,
        options,
        config.address_book
      )
    end
  end

  @spec accept(server(), keyword()) :: {:ok, Connection.t()} | {:error, Error.t()}
  def accept(endpoint, options \\ []) do
    with {:ok, config} <- connection_config(endpoint) do
      Connection.accept(config.owner, config.resource, config.peer_allowlist, options)
    end
  end

  @spec await_online(server()) :: :ok | {:error, Error.t()}
  def await_online(endpoint), do: GenServer.call(endpoint, :await_online, :infinity)

  @spec await_online(server(), timeout()) :: :ok | {:error, Error.t()}
  def await_online(endpoint, timeout) when is_integer(timeout) and timeout > 0 do
    GenServer.call(endpoint, {:await_online, timeout}, timeout + 1_000)
  end

  @impl GenServer
  def init(config) do
    operation_ref = make_ref()

    native_options = %{
      profile: config.profile,
      alpns: config.alpns,
      bind_addrs: config.bind_addrs,
      relays: Enum.map(config.relays, &Relay.to_native/1),
      max_connections: config.limits.max_connections,
      max_pending_accepts: config.limits.max_pending_accepts,
      direct_ip: config.direct_ip
    }

    case Native.endpoint_bind_start(
           self(),
           operation_ref,
           config.secret_key.resource,
           native_options
         ) do
      {:ok, operation} ->
        case await_operation(operation_ref, operation, config.startup_timeout, :endpoint_bind) do
          {:ok, resource} ->
            {:ok, info} = Native.endpoint_info(resource)
            id = EndpointId.from_canonical(info.endpoint_id)

            {:ok,
             %{
               resource: resource,
               id: id,
               profile: config.profile,
               limits: config.limits,
               address_book: config.address_book,
               peer_allowlist: config.peer_allowlist,
               startup_timeout: config.startup_timeout,
               shutdown_timeout: config.shutdown_timeout
             }}

          {:error, error} ->
            {:stop, error}
        end

      {:error, error} ->
        {:stop, Error.from_native(error, :endpoint_bind)}
    end
  end

  @impl GenServer
  def handle_call(:id, _from, state), do: {:reply, {:ok, state.id}, state}

  def handle_call(:connection_config, _from, state) do
    config = %{
      owner: self(),
      resource: state.resource,
      address_book: state.address_book,
      peer_allowlist: state.peer_allowlist
    }

    {:reply, {:ok, config}, state}
  end

  def handle_call(:status, _from, state) do
    case info(state) do
      {:ok, native_info} ->
        status = %{
          status: if(native_info.closed, do: :closed, else: :running),
          id: state.id,
          profile: native_info.profile,
          online?: native_info.online,
          relay_enabled?: native_info.relay_enabled,
          address_lookup_enabled?: native_info.address_lookup_enabled,
          direct_ip?: native_info.direct_ip,
          bound_sockets: native_info.bound_sockets,
          limits: state.limits
        }

        {:reply, {:ok, status}, state}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call(:addr, _from, state) do
    reply =
      with {:ok, native_info} <- info(state) do
        {:ok,
         EndpointAddr.from_normalized(state.id, native_info.relay_urls, native_info.ip_addrs)}
      end

    {:reply, reply, state}
  end

  def handle_call(:bound_sockets, _from, state) do
    reply = with {:ok, native_info} <- info(state), do: {:ok, native_info.bound_sockets}
    {:reply, reply, state}
  end

  def handle_call(:online?, _from, state) do
    online =
      case info(state) do
        {:ok, native_info} -> native_info.online
        {:error, _error} -> false
      end

    {:reply, online, state}
  end

  def handle_call(:await_online, from, state),
    do: handle_call({:await_online, state.startup_timeout}, from, state)

  def handle_call({:await_online, timeout}, _from, state) do
    operation_ref = make_ref()

    reply =
      case Native.endpoint_await_online_start(self(), operation_ref, state.resource) do
        {:ok, operation} ->
          case await_operation(operation_ref, operation, timeout, :endpoint_online) do
            {:ok, :ok} -> :ok
            {:error, error} -> {:error, error}
          end

        {:error, error} ->
          {:error, Error.from_native(error, :endpoint_online)}
      end

    {:reply, reply, state}
  end

  def handle_call(:close, from, state),
    do: handle_call({:close, state.shutdown_timeout}, from, state)

  def handle_call({:close, timeout}, _from, state) do
    operation_ref = make_ref()

    reply =
      case Native.endpoint_close_start(self(), operation_ref, state.resource) do
        {:ok, operation} ->
          case await_operation(operation_ref, operation, timeout, :endpoint_close) do
            {:ok, :closed} ->
              :ok

            {:error, error} ->
              Native.endpoint_abort(state.resource)
              {:error, error}
          end

        {:error, error} ->
          Native.endpoint_abort(state.resource)
          {:error, Error.from_native(error, :endpoint_close)}
      end

    {:stop, :normal, reply, state}
  end

  @impl GenServer
  def terminate(_reason, %{resource: resource}) do
    Native.endpoint_abort(resource)
    :ok
  end

  defp connection_config(endpoint) do
    try do
      GenServer.call(endpoint, :connection_config)
    catch
      :exit, _reason ->
        {:error,
         %Error{
           category: :closed,
           operation: :endpoint,
           message: "endpoint is not running",
           context: %{}
         }}
    end
  end

  defp info(state) do
    case Native.endpoint_info(state.resource) do
      {:ok, info} -> {:ok, info}
      {:error, error} -> {:error, Error.from_native(error, :endpoint_info)}
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

  defp validate_options(options) do
    with true <- Keyword.keyword?(options),
         {:ok, options} <-
           Keyword.validate(options,
             identity: :ephemeral,
             alpns: [],
             network: :n0,
             bind: [],
             direct_ip: true,
             startup_timeout: @default_startup_timeout,
             shutdown_timeout: @default_shutdown_timeout,
             limits: [],
             address_book: [],
             peer_allowlist: :all,
             name: nil,
             id: nil
           ),
         {:ok, secret_key} <- resolve_identity(options[:identity]),
         {:ok, alpns} <- validate_alpns(options[:alpns]),
         {:ok, profile, relays} <- validate_network(options[:network]),
         {:ok, bind_addrs} <- validate_bind(options[:bind]),
         {:ok, direct_ip} <- validate_direct_ip(options[:direct_ip], bind_addrs),
         {:ok, startup_timeout} <- validate_timeout(options[:startup_timeout], :startup_timeout),
         {:ok, shutdown_timeout} <-
           validate_timeout(options[:shutdown_timeout], :shutdown_timeout),
         {:ok, limits} <- validate_limits(options[:limits]),
         {:ok, address_book} <- validate_address_book(options[:address_book]),
         {:ok, peer_allowlist} <- validate_peer_allowlist(options[:peer_allowlist]),
         :ok <- validate_name(options[:name]) do
      {:ok,
       %{
         secret_key: secret_key,
         alpns: alpns,
         profile: profile,
         relays: relays,
         bind_addrs: bind_addrs,
         direct_ip: direct_ip,
         startup_timeout: startup_timeout,
         shutdown_timeout: shutdown_timeout,
         limits: limits,
         address_book: address_book,
         peer_allowlist: peer_allowlist,
         name: options[:name]
       }}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, _reason} -> invalid(:endpoint_start, "endpoint options are invalid")
      false -> invalid(:endpoint_start, "endpoint options are invalid")
    end
  end

  defp resolve_identity(:ephemeral), do: SecretKey.generate()
  defp resolve_identity(%SecretKey{} = secret_key), do: {:ok, secret_key}
  defp resolve_identity({:file, path}) when is_binary(path), do: SecretKey.load_or_create(path)
  defp resolve_identity(_identity), do: invalid(:endpoint_start, "endpoint identity is invalid")

  defp validate_alpns(alpns) when is_list(alpns) and length(alpns) in 1..16 do
    if Enum.all?(
         alpns,
         &(is_binary(&1) and byte_size(&1) in 1..255 and not String.contains?(&1, <<0>>))
       ) and
         length(Enum.uniq(alpns)) == length(alpns) do
      {:ok, alpns}
    else
      invalid(:endpoint_start, "ALPNs must be unique binaries containing 1 to 255 non-NUL bytes")
    end
  end

  defp validate_alpns(_alpns),
    do: invalid(:endpoint_start, "at least one and at most sixteen ALPNs are required")

  defp validate_network(:n0), do: {:ok, :n0, []}
  defp validate_network(network) when network in [:direct, :minimal], do: {:ok, :direct, []}
  defp validate_network(:no_relay), do: {:ok, :no_relay, []}

  defp validate_network({:custom, relays}) when is_list(relays) and length(relays) in 1..8 do
    if Enum.all?(relays, &match?(%Relay{}, &1)) and
         Enum.uniq_by(relays, &Relay.url/1) |> length() == length(relays) do
      {:ok, :custom, relays}
    else
      invalid(:endpoint_start, "custom relays must be unique validated relay records")
    end
  end

  defp validate_network(_network), do: invalid(:endpoint_start, "network profile is invalid")

  defp validate_bind(bind_addrs) when is_list(bind_addrs) and length(bind_addrs) <= 8 do
    if Enum.all?(bind_addrs, &is_binary/1),
      do: {:ok, bind_addrs},
      else: invalid(:endpoint_start, "bind addresses must be strings")
  end

  defp validate_bind(_bind_addrs), do: invalid(:endpoint_start, "bind addresses are invalid")

  defp validate_direct_ip(direct_ip, bind_addrs) when is_boolean(direct_ip) do
    if direct_ip or bind_addrs == [],
      do: {:ok, direct_ip},
      else: invalid(:endpoint_start, "bind addresses require direct IP transports")
  end

  defp validate_direct_ip(_direct_ip, _bind_addrs),
    do: invalid(:endpoint_start, "direct_ip must be a boolean")

  defp validate_timeout(timeout, _name) when is_integer(timeout) and timeout > 0,
    do: {:ok, timeout}

  defp validate_timeout(_timeout, name),
    do: invalid(:endpoint_start, "#{name} must be a positive integer")

  defp validate_limits(limits) when is_list(limits) do
    with true <- Keyword.keyword?(limits),
         {:ok, limits} <-
           Keyword.validate(limits, max_pending_accepts: 64, max_connections: 1_024),
         true <-
           Enum.all?(limits, fn {_name, value} -> is_integer(value) and value > 0 end) do
      {:ok, Map.new(limits)}
    else
      _error -> invalid(:endpoint_start, "endpoint limits must be positive integers")
    end
  end

  defp validate_limits(_limits),
    do: invalid(:endpoint_start, "endpoint limits must be a keyword list")

  defp validate_address_book(addresses) when is_list(addresses) do
    if Enum.all?(addresses, &match?(%EndpointAddr{}, &1)) do
      address_book = Map.new(addresses, &{to_string(&1.id), &1})

      if map_size(address_book) == length(addresses),
        do: {:ok, address_book},
        else: invalid(:endpoint_start, "address book endpoint IDs must be unique")
    else
      invalid(:endpoint_start, "address book must contain EndpointAddr values")
    end
  end

  defp validate_address_book(_addresses),
    do: invalid(:endpoint_start, "address book must be a list")

  defp validate_peer_allowlist(:all), do: {:ok, {true, []}}

  defp validate_peer_allowlist(endpoint_ids) when is_list(endpoint_ids) do
    if Enum.all?(endpoint_ids, &match?(%EndpointId{}, &1)) do
      values = endpoint_ids |> Enum.map(&to_string/1) |> Enum.uniq()
      {:ok, {false, values}}
    else
      invalid(:endpoint_start, "peer allowlist must contain EndpointId values")
    end
  end

  defp validate_peer_allowlist(_allowlist),
    do: invalid(:endpoint_start, "peer allowlist must be :all or a list")

  defp validate_name(nil), do: :ok
  defp validate_name(name) when is_atom(name), do: :ok
  defp validate_name({:global, _term}), do: :ok
  defp validate_name({:via, module, _term}) when is_atom(module), do: :ok
  defp validate_name(_name), do: invalid(:endpoint_start, "endpoint name is invalid")

  defp name_option(nil), do: []
  defp name_option(name), do: [name: name]

  defp invalid(operation, message) do
    {:error,
     %Error{category: :invalid_argument, operation: operation, message: message, context: %{}}}
  end
end
