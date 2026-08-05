defmodule IrohBeam.DistributionTelemetryTest do
  use ExUnit.Case, async: false

  alias IrohBeam.Distribution.Telemetry

  test "distribution events use bounded secret-safe metadata" do
    handler = "distribution-telemetry-#{System.unique_integer([:positive])}"
    parent = self()

    events = [
      [:iroh_beam, :distribution, :node, :up],
      [:iroh_beam, :distribution, :node, :down],
      [:iroh_beam, :distribution, :peer, :rejected]
    ]

    :ok =
      :telemetry.attach_many(
        handler,
        events,
        &__MODULE__.handle_event/4,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert :ok = Telemetry.node_up(%{kind: :direct, remote: "payload-sentinel"})
    assert :ok = Telemetry.rejected(:name_binding)
    assert :ok = Telemetry.node_down()

    assert_receive {:distribution_event, [:iroh_beam, :distribution, :node, :up], %{count: 1},
                    %{path: :direct}}

    assert_receive {:distribution_event, [:iroh_beam, :distribution, :peer, :rejected],
                    %{count: 1}, %{stage: :name_binding}}

    assert_receive {:distribution_event, [:iroh_beam, :distribution, :node, :down], %{count: 1},
                    %{}}
  end

  def handle_event(event, measurements, metadata, parent) do
    send(parent, {:distribution_event, event, measurements, metadata})
  end
end
