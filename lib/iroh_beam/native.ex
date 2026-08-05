defmodule IrohBeam.Native do
  @moduledoc false

  @version Mix.Project.config()[:version]
  @force_build Mix.env() == :test or
                 not File.exists?(
                   Path.expand("../../checksum-Elixir.IrohBeam.Native.exs", __DIR__)
                 ) or
                 String.downcase(System.get_env("IROH_BEAM_BUILD", "")) in [
                   "1",
                   "true",
                   "yes",
                   "on"
                 ]

  use RustlerPrecompiled,
    otp_app: :iroh_beam,
    crate: "iroh_beam_nif",
    base_url: "https://github.com/mindreframer/iroh_beam/releases/download/v#{@version}",
    version: @version,
    nif_versions: ["2.16"],
    targets: ~w(
      aarch64-apple-darwin
      x86_64-apple-darwin
      aarch64-unknown-linux-gnu
      aarch64-unknown-linux-musl
      x86_64-unknown-linux-gnu
      x86_64-unknown-linux-musl
      x86_64-pc-windows-msvc
    ),
    force_build: @force_build,
    path: "native/iroh_beam_nif",
    cargo: {:system, "+1.91.0"},
    mode: if(Mix.env() == :prod, do: :release, else: :debug),
    features: ["nif_version_2_16"]

  alias IrohBeam.Error

  @message_tag __MODULE__

  @spec versions() :: {:ok, map()} | {:error, Error.t()}
  def versions do
    case native_versions() do
      {:ok, versions} -> {:ok, versions}
      {:error, error} -> {:error, Error.from_native(error, :native_versions)}
    end
  end

  @spec request(:ok | :error | :panic, non_neg_integer(), pos_integer()) ::
          {:ok, term()} | {:error, Error.t()}
  def request(kind, delay_ms, timeout_ms)
      when kind in [:ok, :error, :panic] and is_integer(delay_ms) and delay_ms >= 0 and
             is_integer(timeout_ms) and timeout_ms > 0 do
    operation_ref = make_ref()

    with {:ok, operation} <- operation_start(self(), operation_ref, kind, delay_ms) do
      await(operation_ref, operation, timeout_ms)
    else
      {:error, error} -> {:error, Error.from_native(error, :native_smoke)}
    end
  end

  def request(_kind, _delay_ms, _timeout_ms) do
    {:error,
     %Error{
       category: :invalid_argument,
       operation: :native_smoke,
       message: "kind, delay, or timeout is invalid"
     }}
  end

  defp await(operation_ref, operation, timeout_ms) do
    receive do
      {@message_tag, ^operation_ref, {:ok, value}} ->
        {:ok, value}

      {@message_tag, ^operation_ref, {:error, error}} ->
        {:error, Error.from_native(error, :native_smoke)}
    after
      timeout_ms ->
        cancelled? = operation_cancel(operation)

        if cancelled? do
          {:error,
           %Error{category: :timeout, operation: :native_smoke, message: "operation timed out"}}
        else
          receive do
            {@message_tag, ^operation_ref, {:ok, value}} ->
              {:ok, value}

            {@message_tag, ^operation_ref, {:error, error}} ->
              {:error, Error.from_native(error, :native_smoke)}
          after
            10 ->
              {:error,
               %Error{
                 category: :timeout,
                 operation: :native_smoke,
                 message: "operation timed out"
               }}
          end
        end
    end
  end

  def native_versions, do: :erlang.nif_error(:nif_not_loaded)

  def operation_start(_caller, _operation_ref, _kind, _delay_ms),
    do: :erlang.nif_error(:nif_not_loaded)

  def operation_cancel(_operation), do: :erlang.nif_error(:nif_not_loaded)
  def operation_snapshot, do: :erlang.nif_error(:nif_not_loaded)

  def identity_generate, do: :erlang.nif_error(:nif_not_loaded)
  def identity_load_or_create(_path), do: :erlang.nif_error(:nif_not_loaded)
  def secret_key_import(_bytes), do: :erlang.nif_error(:nif_not_loaded)
  def secret_key_export(_secret_key), do: :erlang.nif_error(:nif_not_loaded)
  def secret_key_endpoint_id(_secret_key), do: :erlang.nif_error(:nif_not_loaded)
  def endpoint_id_parse(_text), do: :erlang.nif_error(:nif_not_loaded)
  def endpoint_id_from_bytes(_bytes), do: :erlang.nif_error(:nif_not_loaded)

  def endpoint_addr_normalize(_endpoint_id, _relay_urls, _ip_addrs),
    do: :erlang.nif_error(:nif_not_loaded)

  def endpoint_ticket_from_addr_text(_endpoint_id, _relay_urls, _ip_addrs),
    do: :erlang.nif_error(:nif_not_loaded)

  def endpoint_ticket_from_addr_bytes(_endpoint_id, _relay_urls, _ip_addrs),
    do: :erlang.nif_error(:nif_not_loaded)

  def endpoint_ticket_parse_text(_text), do: :erlang.nif_error(:nif_not_loaded)
  def endpoint_ticket_parse_bytes(_bytes), do: :erlang.nif_error(:nif_not_loaded)
  def endpoint_ticket_text_to_bytes(_text), do: :erlang.nif_error(:nif_not_loaded)
end
