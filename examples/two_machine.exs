defmodule IrohBeam.Examples.TwoMachine do
  @moduledoc false

  alias IrohBeam.{Connection, Endpoint, EndpointTicket, Relay, Stream}

  @alpn "iroh-beam/two-machine/1"

  def main(["listen"]) do
    {:ok, endpoint} = Endpoint.start_link(endpoint_options("listener"))
    :ok = Endpoint.await_online(endpoint, 30_000)
    {:ok, addr} = Endpoint.addr(endpoint)
    {:ok, ticket} = EndpointTicket.new(addr)

    IO.puts("Share this endpoint ticket with the connector:")
    IO.puts(to_string(ticket))

    {:ok, connection} = Endpoint.accept(endpoint, timeout: 120_000)
    {:ok, stream} = Connection.accept_uni(connection, timeout: 30_000)
    {:ok, payload} = Stream.recv_to_end(stream, 16 * 1_024 * 1_024, timeout: 30_000)
    IO.puts("Received #{byte_size(payload)} bytes over #{inspect(Connection.path(connection))}")

    Stream.abort(stream)
    Connection.close(connection)
    Endpoint.close(endpoint)
  end

  def main(["connect", ticket_text]) do
    {:ok, ticket} = EndpointTicket.parse(ticket_text)
    {:ok, endpoint} = Endpoint.start_link(endpoint_options("connector"))
    :ok = Endpoint.await_online(endpoint, 30_000)
    {:ok, connection} = Endpoint.connect(endpoint, ticket, @alpn, timeout: 30_000)
    {:ok, stream} = Connection.open_uni(connection, timeout: 30_000)
    payload = System.get_env("IROH_BEAM_MESSAGE", "hello from another machine")
    :ok = Stream.send(stream, payload, timeout: 30_000)
    :ok = Stream.finish(stream)
    IO.puts("Sent #{byte_size(payload)} bytes over #{inspect(Connection.path(connection))}")

    Stream.abort(stream)
    Connection.close(connection)
    Endpoint.close(endpoint)
  end

  def main(_arguments) do
    IO.puts(:stderr, "usage: mix run examples/two_machine.exs listen")
    IO.puts(:stderr, "   or: mix run examples/two_machine.exs connect ENDPOINT_TICKET")
    System.halt(2)
  end

  defp endpoint_options(role) do
    identity_path =
      System.get_env("IROH_BEAM_IDENTITY", Path.join("data", "two-machine-#{role}.identity"))

    [
      identity: {:file, identity_path},
      alpns: [@alpn],
      network: network_profile(),
      startup_timeout: 30_000,
      shutdown_timeout: 5_000
    ]
  end

  defp network_profile do
    case System.get_env("IROH_BEAM_RELAY_URL") do
      nil ->
        :n0

      url ->
        options =
          case System.get_env("IROH_BEAM_RELAY_TOKEN") do
            nil -> []
            token -> [token: token]
          end

        {:ok, relay} = Relay.new(url, options)
        {:custom, [relay]}
    end
  end
end

IrohBeam.Examples.TwoMachine.main(System.argv())
