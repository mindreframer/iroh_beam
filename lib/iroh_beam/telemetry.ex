defmodule IrohBeam.Telemetry do
  @moduledoc """
  Secret-safe telemetry emitted by IrohBeam.

  Events use the `[:iroh_beam, ...]` prefix. Every span emits `:start` and
  `:stop`; exceptions additionally emit `:exception`. Measurements use native
  units (`:duration` in monotonic time and `:bytes` as a non-negative integer).
  Metadata is bounded to operation/profile/path/outcome/category values. Private
  keys, relay tokens, payloads, close reasons, socket addresses, endpoint IDs,
  tickets, and native debug chains are never included.
  """

  @type prefix :: [atom()]

  @doc false
  def span(prefix, metadata \\ %{}, fun)
      when is_list(prefix) and is_map(metadata) and is_function(fun, 0) do
    started = System.monotonic_time()
    safe_execute(prefix ++ [:start], %{system_time: System.system_time()}, metadata)

    try do
      result = fun.()
      measurements = %{duration: System.monotonic_time() - started, bytes: result_bytes(result)}
      stop_metadata = Map.merge(metadata, outcome_metadata(result))
      safe_execute(prefix ++ [:stop], measurements, stop_metadata)
      result
    rescue
      exception ->
        safe_execute(
          prefix ++ [:exception],
          %{duration: System.monotonic_time() - started},
          Map.merge(metadata, %{kind: :error})
        )

        reraise exception, __STACKTRACE__
    catch
      kind, reason ->
        safe_execute(
          prefix ++ [:exception],
          %{duration: System.monotonic_time() - started},
          Map.merge(metadata, %{kind: kind})
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @doc false
  def cancelled(operation) when is_atom(operation) do
    safe_execute(
      [:iroh_beam, :operation, :cancelled],
      %{count: 1},
      %{operation: operation, outcome: :cancelled}
    )
  end

  @doc false
  def event(prefix, measurements, metadata)
      when is_list(prefix) and is_map(measurements) and is_map(metadata) do
    safe_execute(prefix, measurements, metadata)
  end

  defp outcome_metadata({:error, %{category: category}}),
    do: %{outcome: :error, category: category}

  defp outcome_metadata({:error, _reason}), do: %{outcome: :error}
  defp outcome_metadata(_result), do: %{outcome: :ok}

  defp result_bytes({:ok, binary}) when is_binary(binary), do: byte_size(binary)
  defp result_bytes(_result), do: 0

  defp safe_execute(event, measurements, metadata) do
    :telemetry.execute(event, measurements, metadata)
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end
end
