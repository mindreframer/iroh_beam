defmodule IrohBeam.TelemetryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias IrohBeam.{Connection, Endpoint, Stream}

  @alpn "iroh-beam/telemetry-test/1"
  @payload "payload-must-not-appear-in-telemetry"
  @events [
    [:iroh_beam, :endpoint, :start, :start],
    [:iroh_beam, :endpoint, :start, :stop],
    [:iroh_beam, :connection, :connect, :start],
    [:iroh_beam, :connection, :connect, :stop],
    [:iroh_beam, :connection, :accept, :start],
    [:iroh_beam, :connection, :accept, :stop],
    [:iroh_beam, :connection, :path, :selected],
    [:iroh_beam, :stream, :send, :stop],
    [:iroh_beam, :stream, :recv, :stop],
    [:iroh_beam, :datagram, :send, :stop],
    [:iroh_beam, :datagram, :recv, :stop],
    [:iroh_beam, :operation, :cancelled]
  ]

  test "transport events have safe bounded metadata, units, pairing, and cancellation" do
    test_pid = self()
    handler_id = "iroh-beam-telemetry-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        @events,
        &__MODULE__.handle_event/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, client_endpoint} = start_endpoint()
    {:ok, server_endpoint} = start_endpoint()
    {:ok, server_addr} = Endpoint.addr(server_endpoint)
    accept = Task.async(fn -> Endpoint.accept(server_endpoint, timeout: 3_000) end)
    {:ok, client} = Endpoint.connect(client_endpoint, server_addr, @alpn)
    {:ok, server} = Task.await(accept, 4_000)
    assert {:ok, %{kind: :direct}} = Connection.path(client)

    {:ok, sender} = Connection.open_uni(client)
    stream_accept = Task.async(fn -> Connection.accept_uni(server, timeout: 3_000) end)
    assert :ok = Stream.send(sender, @payload)
    assert :ok = Stream.finish(sender)
    {:ok, receiver} = Task.await(stream_accept, 4_000)
    assert {:ok, @payload} = Stream.recv(receiver, 1_024)
    assert :eof = Stream.recv(receiver, 1_024)

    assert :ok = Connection.send_datagram(client, "telemetry-datagram")
    assert {:ok, "telemetry-datagram"} = Connection.recv_datagram(server)
    assert {:error, %{category: :timeout}} = Connection.recv_datagram(server, timeout: 5)

    Stream.abort(sender)
    Stream.abort(receiver)
    Connection.close(client)
    Connection.close(server)
    Endpoint.close(client_endpoint)
    Endpoint.close(server_endpoint)

    events = collect_events([])
    names = Enum.map(events, &elem(&1, 0))

    assert [:iroh_beam, :connection, :connect, :start] in names
    assert [:iroh_beam, :connection, :connect, :stop] in names
    assert [:iroh_beam, :operation, :cancelled] in names

    for {event, measurements, metadata} <- events do
      serialized = inspect({event, measurements, metadata}, limit: :infinity)
      refute serialized =~ @payload
      refute serialized =~ "telemetry-datagram"
      refute Map.has_key?(metadata, :endpoint_id)
      refute Map.has_key?(metadata, :token)

      if List.last(event) == :stop do
        assert is_integer(measurements.duration)
        assert measurements.duration >= 0
        assert is_integer(measurements.bytes)
        assert measurements.bytes >= 0
        assert metadata.outcome in [:ok, :error]
      end
    end
  end

  test "telemetry handler failures never affect transport calls" do
    handler_id = "iroh-beam-bad-handler-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:iroh_beam, :endpoint, :start, :start],
        &__MODULE__.failing_handler/4,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    capture_log(fn ->
      assert {:ok, endpoint} = start_endpoint()
      assert :ok = Endpoint.close(endpoint)
    end)
  end

  def handle_event(event, measurements, metadata, pid) do
    send(pid, {:telemetry, event, measurements, metadata})
  end

  def failing_handler(_event, _measurements, _metadata, _config), do: raise("handler failed")

  defp collect_events(events) do
    receive do
      {:telemetry, event, measurements, metadata} ->
        collect_events([{event, measurements, metadata} | events])
    after
      50 -> Enum.reverse(events)
    end
  end

  defp start_endpoint do
    Endpoint.start_link(alpns: [@alpn], network: :direct, bind: ["127.0.0.1:0"])
  end
end
