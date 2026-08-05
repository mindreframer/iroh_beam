defmodule IrohBeam.MultiBeamHelper do
  @moduledoc false

  alias IrohBeam.{Connection, Endpoint, Stream}

  def start_endpoint(options) do
    caller = self()

    owner =
      spawn(fn ->
        result =
          with {:ok, endpoint} <- Endpoint.start_link(options),
               :ok <- Endpoint.await_online(endpoint, 10_000),
               {:ok, id} <- Endpoint.id(endpoint),
               {:ok, addr} <- Endpoint.addr(endpoint) do
            {:ok, endpoint, id, addr}
          end

        send(caller, {:endpoint_started, self(), result})

        case result do
          {:ok, endpoint, _id, _addr} -> loop(endpoint)
          _error -> :ok
        end
      end)

    receive do
      {:endpoint_started, ^owner, {:ok, _endpoint, id, addr}} ->
        {:ok, %{owner: owner, id: id, addr: addr}}

      {:endpoint_started, ^owner, {:error, error}} ->
        {:error, error}
    after
      15_000 -> {:error, :remote_endpoint_start_timeout}
    end
  end

  def receive_payload(owner, alpn, size), do: call(owner, {:receive_payload, alpn, size}, 20_000)

  def send_payload(owner, target, alpn, size),
    do: call(owner, {:send_payload, target, alpn, size}, 20_000)

  def stop_endpoint(owner), do: call(owner, :stop, 10_000)

  defp call(owner, request, timeout) do
    reference = make_ref()
    monitor = Process.monitor(owner)
    send(owner, {:call, self(), reference, request})

    receive do
      {:reply, ^reference, reply} ->
        Process.demonitor(monitor, [:flush])
        reply

      {:DOWN, ^monitor, :process, ^owner, reason} ->
        {:error, {:remote_owner_down, reason}}
    after
      timeout ->
        Process.demonitor(monitor, [:flush])
        {:error, :remote_call_timeout}
    end
  end

  defp loop(endpoint) do
    receive do
      {:call, from, reference, {:receive_payload, _alpn, size}} ->
        result =
          with {:ok, connection} <- Endpoint.accept(endpoint, timeout: 10_000),
               {:ok, stream} <- Connection.accept_bi(connection, timeout: 10_000),
               {:ok, payload} <- Stream.recv_to_end(stream, size, timeout: 10_000),
               :ok <- Stream.send(stream, "ok", timeout: 10_000),
               :ok <- Stream.finish(stream),
               {:ok, path} <- Connection.path(connection),
               :ok <- Connection.closed(connection, 10_000) do
            Stream.abort(stream)
            {:ok, %{bytes: byte_size(payload), hash: :crypto.hash(:sha256, payload), path: path}}
          end

        send(from, {:reply, reference, result})
        loop(endpoint)

      {:call, from, reference, {:send_payload, target, alpn, size}} ->
        payload = :binary.copy(<<0xA5>>, size)

        result =
          with {:ok, connection} <- Endpoint.connect(endpoint, target, alpn, timeout: 10_000),
               {:ok, stream} <- Connection.open_bi(connection, timeout: 10_000),
               :ok <- Stream.send(stream, payload, chunk_size: 32 * 1_024, timeout: 10_000),
               :ok <- Stream.finish(stream),
               {:ok, "ok"} <- Stream.recv_to_end(stream, 2, timeout: 10_000),
               {:ok, path} <- Connection.path(connection) do
            Stream.abort(stream)
            Connection.close(connection)
            {:ok, %{bytes: size, hash: :crypto.hash(:sha256, payload), path: path}}
          end

        send(from, {:reply, reference, result})
        loop(endpoint)

      {:call, from, reference, :stop} ->
        result = if Process.alive?(endpoint), do: Endpoint.close(endpoint), else: :ok
        send(from, {:reply, reference, result})

      _other ->
        loop(endpoint)
    end
  end
end
