defmodule IrohBeam.Error do
  @moduledoc """
  Stable, secret-safe error returned by IrohBeam operations.

  Common categories include `:invalid_argument`, `:resolution`, `:refused`,
  `:unauthorized`, `:timeout`, `:cancelled`, `:busy`, `:capacity`, `:closed`,
  `:peer_aborted`, `:too_large`, `:bind_failed`, `:duplicate_identity`,
  `:native_failure`, and `:internal`. Native debug chains, peer close text, and
  panic payloads are deliberately excluded.
  """

  @enforce_keys [:category, :operation, :message]
  defexception [:category, :operation, :message, context: %{}]

  @type category ::
          :cancelled
          | :internal
          | :invalid_argument
          | :native_failure
          | :timeout
          | atom()

  @type t :: %__MODULE__{
          category: category(),
          operation: atom(),
          message: String.t(),
          context: map()
        }

  @impl Exception
  def message(%__MODULE__{operation: operation, message: message}) do
    "#{operation}: #{message}"
  end

  @doc false
  @spec from_native(map(), atom()) :: t()
  def from_native(error, fallback_operation) when is_map(error) do
    %__MODULE__{
      category: Map.get(error, :category, :internal),
      operation: Map.get(error, :operation, fallback_operation),
      message: Map.get(error, :message, "native operation failed"),
      context: Map.get(error, :context, %{})
    }
  end
end
