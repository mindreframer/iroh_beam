defmodule IrohBeam do
  @moduledoc """
  Embedded, supervised Iroh transport for Elixir.

  The default API is a general application transport. OTP 29 applications may
  additionally opt into `IrohBeam.Distribution`, which carries native Erlang
  distribution over Iroh without EPMD. The optional carrier preserves OTP
  cookies, RPC, links, monitors, and ticks but does not provide membership,
  topology management, or automatic reconnect. Each live endpoint or VM owns a
  distinct private identity.
  """

  alias IrohBeam.{Endpoint, Native}

  @doc "Returns the versions built into the loaded native library."
  @spec native_versions() :: {:ok, map()} | {:error, IrohBeam.Error.t()}
  def native_versions, do: Native.versions()

  @doc "Runs a small operation on the managed native Tokio runtime."
  @spec native_smoke(keyword()) :: {:ok, :completed} | {:error, IrohBeam.Error.t()}
  def native_smoke(options \\ []) do
    delay = Keyword.get(options, :delay, 1)
    timeout = Keyword.get(options, :timeout, 5_000)
    Native.request(:ok, delay, timeout)
  end

  @doc "Starts a supervised Iroh endpoint."
  @spec start_endpoint(keyword()) :: GenServer.on_start()
  defdelegate start_endpoint(options), to: Endpoint, as: :start_link

  @doc "Dials an authenticated endpoint ID, address, or ticket with an application ALPN."
  defdelegate connect(endpoint, target, alpn, options \\ []), to: Endpoint

  @doc "Accepts one authenticated incoming connection on demand."
  defdelegate accept(endpoint, options \\ []), to: Endpoint

  @doc false
  @spec native_smoke_error() :: {:error, IrohBeam.Error.t()}
  def native_smoke_error, do: Native.request(:error, 0, 5_000)
end
