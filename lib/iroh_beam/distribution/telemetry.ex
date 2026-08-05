defmodule IrohBeam.Distribution.Telemetry do
  @moduledoc false

  def node_up(path) do
    kind = if is_map(path), do: Map.get(path, :kind, :unknown), else: :unknown
    execute([:iroh_beam, :distribution, :node, :up], %{count: 1}, %{path: kind})
  end

  def node_down do
    execute([:iroh_beam, :distribution, :node, :down], %{count: 1}, %{})
  end

  def rejected(stage) when stage in [:relay, :endpoint_id, :name_binding, :cookie, :frame] do
    execute([:iroh_beam, :distribution, :peer, :rejected], %{count: 1}, %{stage: stage})
  end

  defp execute(event, measurements, metadata) do
    if Code.ensure_loaded?(:telemetry) do
      :telemetry.execute(event, measurements, metadata)
    end

    :ok
  end
end
