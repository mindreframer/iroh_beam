defmodule IrohBeam.Distribution.Config do
  @moduledoc false

  alias IrohBeam.{EndpointAddr, EndpointId, EndpointTicket, Error, Relay, SecretKey}

  @alpn "iroh-beam/erlang-distribution/1"
  @bootstrap_key {__MODULE__, :bootstrap}
  @default_startup_timeout 10_000
  @default_shutdown_timeout 5_000
  @default_connect_timeout 10_000
  @default_accept_timeout 1_000
  @default_stream_timeout 10_000
  @default_receive_chunk 64 * 1024
  @default_max_frame 16 * 1024 * 1024

  @enforce_keys [
    :mode,
    :name,
    :name_domain,
    :identity,
    :network,
    :bind,
    :direct_ip,
    :peers,
    :ids,
    :startup_timeout,
    :shutdown_timeout,
    :connect_timeout,
    :accept_timeout,
    :stream_timeout,
    :receive_chunk,
    :max_frame,
    :max_connections
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  def alpn, do: @alpn

  def validate(options, mode \\ :dynamic)

  def validate(options, mode) when is_list(options) and mode in [:dynamic, :early] do
    with true <- Keyword.keyword?(options),
         {:ok, options} <-
           Keyword.validate(options,
             name: nil,
             name_domain: :shortnames,
             identity: nil,
             network: nil,
             bind: [],
             direct_ip: true,
             peers: %{},
             startup_timeout: @default_startup_timeout,
             shutdown_timeout: @default_shutdown_timeout,
             connect_timeout: @default_connect_timeout,
             accept_timeout: @default_accept_timeout,
             stream_timeout: @default_stream_timeout,
             receive_chunk: @default_receive_chunk,
             max_frame: @default_max_frame,
             max_connections: 1_024
           ),
         :ok <- require_keys(options, [:name, :identity, :network]),
         :ok <- validate_node(options[:name]),
         :ok <- validate_name_domain(options[:name], options[:name_domain]),
         :ok <- validate_identity(options[:identity]),
         :ok <- validate_network(options[:network]),
         :ok <- validate_bind(options[:bind], options[:direct_ip]),
         {:ok, peers, ids} <- normalize_peers(options[:peers], options[:name]),
         :ok <- validate_limits(options) do
      {:ok,
       struct!(__MODULE__,
         mode: mode,
         name: options[:name],
         name_domain: options[:name_domain],
         identity: options[:identity],
         network: options[:network],
         bind: options[:bind],
         direct_ip: options[:direct_ip],
         peers: peers,
         ids: ids,
         startup_timeout: options[:startup_timeout],
         shutdown_timeout: options[:shutdown_timeout],
         connect_timeout: options[:connect_timeout],
         accept_timeout: options[:accept_timeout],
         stream_timeout: options[:stream_timeout],
         receive_chunk: options[:receive_chunk],
         max_frame: options[:max_frame],
         max_connections: options[:max_connections]
       )}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, _} -> invalid("distribution options contain unknown keys")
      false -> invalid("distribution options must be a keyword list")
    end
  end

  def validate(_options, _mode), do: invalid("distribution options must be a keyword list")

  def install(%__MODULE__{} = config) do
    case :persistent_term.get(@bootstrap_key, :undefined) do
      :undefined ->
        :persistent_term.put(@bootstrap_key, config)
        :ok

      _ ->
        {:error, error(:already_started, "distribution configuration is already installed")}
    end
  end

  def uninstall do
    :persistent_term.erase(@bootstrap_key)
    :ok
  end

  def load do
    case :persistent_term.get(@bootstrap_key, :undefined) do
      %__MODULE__{} = config -> {:ok, config}
      :undefined -> load_early()
    end
  end

  def get, do: :persistent_term.get(@bootstrap_key, :undefined)

  def resolve(%__MODULE__{peers: peers}, node) when is_atom(node) do
    case Map.fetch(peers, node) do
      {:ok, peer} -> {:ok, peer}
      :error -> {:error, :unknown_peer}
    end
  end

  def authorize_id(%__MODULE__{ids: ids}, id) do
    Map.fetch(ids, to_string(id))
  end

  def expected_id(%__MODULE__{} = config, node) do
    with {:ok, peer} <- resolve(config, node), do: {:ok, peer.id}
  end

  def authorize_claim(%__MODULE__{} = config, remote_name, remote_id, target_name)
      when is_binary(remote_name) and is_binary(target_name) do
    expected_target = Atom.to_string(config.name)

    with true <- target_name == expected_target,
         {node, peer} when not is_nil(node) <-
           Enum.find(config.peers, fn {node, _peer} -> Atom.to_string(node) == remote_name end),
         true <- peer.id == remote_id do
      {:ok, node}
    else
      _ -> {:error, :identity_name_mismatch}
    end
  end

  def allowed_nodes(%__MODULE__{peers: peers}), do: Map.keys(peers)

  def endpoint_options(%__MODULE__{} = config) do
    [
      identity: config.identity,
      alpns: [@alpn],
      network: config.network,
      bind: config.bind,
      direct_ip: config.direct_ip,
      startup_timeout: config.startup_timeout,
      shutdown_timeout: config.shutdown_timeout,
      limits: [max_connections: config.max_connections, max_pending_accepts: 1],
      peer_allowlist: Enum.map(config.peers, fn {_node, peer} -> peer.id end)
    ]
  end

  def safe(%__MODULE__{} = config) do
    %{
      mode: config.mode,
      name: config.name,
      name_domain: config.name_domain,
      network: safe_network(config.network),
      direct_ip: config.direct_ip,
      configured_peers: map_size(config.peers),
      receive_chunk: config.receive_chunk,
      max_frame: config.max_frame,
      max_connections: config.max_connections
    }
  end

  defp load_early do
    _ = Application.load(:iroh_beam)

    case Application.get_env(:iroh_beam, :distribution) do
      options when is_list(options) ->
        with {:ok, config} <- validate(options, :early),
             :ok <- install(config) do
          {:ok, config}
        end

      _ ->
        invalid("boot-time :iroh_beam distribution configuration is missing")
    end
  end

  defp require_keys(options, keys) do
    if Enum.all?(keys, &(not is_nil(options[&1]))),
      do: :ok,
      else: invalid("name, identity, and network are required")
  end

  defp validate_node(node) when is_atom(node) do
    case String.split(Atom.to_string(node), "@", parts: 3) do
      [name, host] when name != "" and host != "" -> :ok
      _ -> invalid("node names must be exact atoms in name@host form")
    end
  end

  defp validate_node(_node), do: invalid("node names must be exact atoms in name@host form")

  defp validate_name_domain(node, :shortnames) do
    [_name, host] = String.split(Atom.to_string(node), "@")

    if String.contains?(host, "."),
      do: invalid("short node names require a host without dots"),
      else: :ok
  end

  defp validate_name_domain(node, :longnames) do
    [_name, host] = String.split(Atom.to_string(node), "@")

    if String.contains?(host, "."),
      do: :ok,
      else: invalid("long node names require a fully qualified host")
  end

  defp validate_name_domain(_node, _domain),
    do: invalid("name_domain must be :shortnames or :longnames")

  defp validate_identity(:ephemeral), do: :ok
  defp validate_identity(%SecretKey{}), do: :ok
  defp validate_identity({:file, path}) when is_binary(path) and byte_size(path) > 0, do: :ok
  defp validate_identity(_identity), do: invalid("distribution identity is invalid")

  defp validate_network(network) when network in [:n0, :direct, :minimal, :no_relay], do: :ok

  defp validate_network({:custom, relays}) when is_list(relays) and length(relays) in 1..8 do
    if Enum.all?(relays, &match?(%Relay{}, &1)),
      do: :ok,
      else: invalid("custom network requires validated relay records")
  end

  defp validate_network(_network), do: invalid("distribution network profile is invalid")

  defp validate_bind(bind, direct_ip)
       when is_list(bind) and length(bind) <= 8 and is_boolean(direct_ip) do
    cond do
      not Enum.all?(bind, &is_binary/1) -> invalid("bind addresses must be strings")
      not direct_ip and bind != [] -> invalid("bind addresses require direct IP transports")
      true -> :ok
    end
  end

  defp validate_bind(_bind, _direct_ip), do: invalid("bind/direct_ip configuration is invalid")

  defp normalize_peers(peers, local) when is_map(peers) do
    Enum.reduce_while(peers, {:ok, %{}, %{}}, fn {node, target}, {:ok, by_node, by_id} ->
      with :ok <- validate_node(node),
           true <- node != local,
           {:ok, target, id} <- normalize_target(target),
           false <- Map.has_key?(by_id, to_string(id)) do
        peer = %{target: target, id: id}
        {:cont, {:ok, Map.put(by_node, node, peer), Map.put(by_id, to_string(id), node)}}
      else
        false -> {:halt, invalid("peer endpoint IDs must be unique and local node is not a peer")}
        true -> {:halt, invalid("peer endpoint IDs must be unique and local node is not a peer")}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp normalize_peers(_peers, _local), do: invalid("peers must be a map")

  defp normalize_target(%EndpointId{} = id), do: {:ok, id, id}
  defp normalize_target(%EndpointAddr{} = addr), do: {:ok, addr, addr.id}

  defp normalize_target(%EndpointTicket{} = ticket) do
    addr = EndpointTicket.endpoint_addr(ticket)
    {:ok, ticket, addr.id}
  end

  defp normalize_target({:id, text}) when is_binary(text) do
    with {:ok, id} <- EndpointId.parse(text), do: {:ok, id, id}
  end

  defp normalize_target({:ticket, text}) when is_binary(text) do
    with {:ok, ticket} <- EndpointTicket.parse(text), do: normalize_target(ticket)
  end

  defp normalize_target({:addr, %EndpointAddr{} = addr}), do: normalize_target(addr)

  defp normalize_target({:addr, value}) when is_map(value) do
    endpoint_id = Map.get(value, :endpoint_id) || Map.get(value, "endpoint_id")
    relay_urls = Map.get(value, :relay_urls) || Map.get(value, "relay_urls") || []
    ip_addrs = Map.get(value, :ip_addrs) || Map.get(value, "ip_addrs") || []

    with {:ok, id} <- EndpointId.parse(endpoint_id),
         {:ok, addr} <- EndpointAddr.new(id, relay_urls: relay_urls, ip_addrs: ip_addrs) do
      normalize_target(addr)
    end
  end

  defp normalize_target(_target), do: invalid("peer target is invalid")

  defp validate_limits(options) do
    timeout_keys = [
      :startup_timeout,
      :shutdown_timeout,
      :connect_timeout,
      :accept_timeout,
      :stream_timeout
    ]

    cond do
      not Enum.all?(timeout_keys, &(is_integer(options[&1]) and options[&1] > 0)) ->
        invalid("distribution timeouts must be positive integers")

      not (is_integer(options[:receive_chunk]) and options[:receive_chunk] in 1..(1024 * 1024)) ->
        invalid("receive_chunk must be between 1 and 1048576 bytes")

      not (is_integer(options[:max_frame]) and options[:max_frame] in 1024..(64 * 1024 * 1024)) ->
        invalid("max_frame must be between 1024 and 67108864 bytes")

      options[:receive_chunk] > options[:max_frame] ->
        invalid("receive_chunk may not exceed max_frame")

      not (is_integer(options[:max_connections]) and options[:max_connections] in 1..1_000_000) ->
        invalid("max_connections is outside the supported range")

      true ->
        :ok
    end
  end

  defp safe_network({:custom, relays}),
    do:
      {:custom,
       Enum.map(relays, fn relay ->
         %{url: Relay.url(relay), token?: Map.get(relay, :token) != nil}
       end)}

  defp safe_network(network), do: network

  defp invalid(message), do: {:error, error(:invalid_argument, message)}

  defp error(category, message) do
    %Error{category: category, operation: :distribution, message: message, context: %{}}
  end
end
