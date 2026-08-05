defmodule IrohBeam.Relay do
  @moduledoc """
  Validated, secret-safe custom relay configuration.

  The optional token is sent as relay authorization and is always redacted from
  inspection. It is unrelated to endpoint identity and may be shared by a group
  admitted to the same private relay.
  """

  alias IrohBeam.Error

  @enforce_keys [:url]
  defstruct [:url, :token]

  @opaque t :: %__MODULE__{url: String.t(), token: String.t() | nil}

  @spec new(String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(url, options \\ [])

  def new(url, options) when is_binary(url) and is_list(options) do
    with true <- Keyword.keyword?(options),
         {:ok, options} <- Keyword.validate(options, token: nil),
         {:ok, normalized_url} <- validate_url(url),
         :ok <- validate_token(options[:token]) do
      {:ok, %__MODULE__{url: normalized_url, token: options[:token]}}
    else
      _error -> invalid("relay URL or token is invalid")
    end
  end

  def new(_url, _options), do: invalid("relay URL or token is invalid")

  @doc false
  def to_native(%__MODULE__{url: url, token: token}), do: %{url: url, token: token}

  @spec url(t()) :: String.t()
  def url(%__MODULE__{url: url}), do: url

  defp validate_url(url) when byte_size(url) <= 2_048 do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil} = uri}
      when scheme in ["http", "https"] and is_binary(host) ->
        normalized = if uri.path in [nil, ""], do: %{uri | path: "/"}, else: uri
        {:ok, URI.to_string(normalized)}

      _other ->
        :error
    end
  end

  defp validate_url(_url), do: :error

  defp validate_token(nil), do: :ok

  defp validate_token(token)
       when is_binary(token) and byte_size(token) > 0 and byte_size(token) <= 4_096 do
    if String.contains?(token, ["\r", "\n"]), do: :error, else: :ok
  end

  defp validate_token(_token), do: :error

  defp invalid(message) do
    {:error,
     %Error{category: :invalid_argument, operation: :relay, message: message, context: %{}}}
  end
end

defimpl Inspect, for: IrohBeam.Relay do
  import Inspect.Algebra

  def inspect(relay, _options) do
    suffix = if relay.token, do: " token=redacted", else: ""
    concat(["#IrohBeam.Relay<", relay.url, suffix, ">"])
  end
end
