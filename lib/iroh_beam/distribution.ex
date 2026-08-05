defmodule IrohBeam.Distribution do
  @moduledoc """
  Opt-in OTP 29 Erlang distribution over an authenticated Iroh transport.

  This module starts or stops dynamic distribution. It does not discover
  members or call `Node.connect/1`; callers configure exact peers and choose
  their own topology.
  """

  alias IrohBeam.{Distribution.Config, Error}

  @spec start(keyword()) :: {:ok, pid()} | {:error, Error.t()}
  def start(options) do
    with :ok <- require_unnamed(),
         :ok <- require_init_arguments(),
         {:ok, config} <- Config.validate(options, :dynamic),
         :ok <- Config.install(config) do
      case :net_kernel.start(config.name, %{name_domain: config.name_domain}) do
        {:ok, pid} ->
          case :iroh_dist_endpoint.status() do
            {:ok, %{ready: true}} -> {:ok, pid}
            _ -> rollback_start("distribution endpoint did not become ready")
          end

        {:error, reason} ->
          Config.uninstall()
          {:error, error(:distribution_start, "net_kernel could not start", reason)}
      end
    end
  end

  @spec stop() :: :ok | {:error, Error.t()}
  def stop do
    case Config.get() do
      %Config{mode: :dynamic} ->
        case :net_kernel.stop() do
          :ok ->
            Config.uninstall()
            :ok

          {:error, reason} ->
            {:error, error(:distribution_stop, "net_kernel could not stop", reason)}
        end

      %Config{mode: :early} ->
        {:error, error(:distribution_stop, "early distribution cannot be stopped dynamically")}

      :undefined ->
        {:error, error(:distribution_stop, "Iroh distribution is not running")}
    end
  end

  @spec status() :: {:ok, map()} | {:error, Error.t()}
  def status do
    case :iroh_dist_endpoint.status() do
      {:ok, status} ->
        {:ok, status}

      {:error, reason} ->
        {:error, error(:distribution_status, "distribution endpoint is unavailable", reason)}
    end
  end

  @spec peer_info(node()) :: {:ok, map()} | {:error, Error.t()}
  def peer_info(node) when is_atom(node) do
    case :iroh_dist_endpoint.peer_info(node) do
      {:ok, info} ->
        {:ok, info}

      {:error, reason} ->
        {:error, error(:distribution_peer, "distribution peer is unavailable", reason)}
    end
  end

  def peer_info(_node),
    do: {:error, error(:distribution_peer, "peer must be a configured node atom")}

  defp require_unnamed do
    if Node.alive?(),
      do: {:error, error(:distribution_start, "the VM is already distributed")},
      else: :ok
  end

  defp require_init_arguments do
    protos =
      case :init.get_argument(:proto_dist) do
        {:ok, [values | _]} -> Enum.map(values, &List.to_string/1)
        _ -> []
      end

    no_epmd? = match?({:ok, _}, :init.get_argument(:no_epmd))

    cond do
      "iroh" not in protos ->
        {:error, error(:distribution_start, "launch the VM with -proto_dist iroh")}

      not no_epmd? ->
        {:error, error(:distribution_start, "launch the VM with -no_epmd")}

      true ->
        :ok
    end
  end

  defp rollback_start(message) do
    _ = :net_kernel.stop()
    Config.uninstall()
    {:error, error(:distribution_start, message)}
  end

  defp error(operation, message, reason \\ nil) do
    context = if is_nil(reason), do: %{}, else: %{reason: inspect(reason)}
    %Error{category: :invalid_argument, operation: operation, message: message, context: context}
  end
end
