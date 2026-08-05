defmodule IrohBeam.RelayIntegrationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import IrohBeam.Eventually

  alias IrohBeam.{Connection, Endpoint, Error, MultiBeamHelper, Relay, Stream}

  @moduletag :relay
  @relay_url "http://127.0.0.1:3340"
  @token "iroh-beam-local-test-token-not-for-production"
  @alpn "iroh-beam/private-relay-test/1"

  setup do
    assert relay_ready?()
    :ok
  end

  test "forced relay-only endpoints exchange bounded oversized stream data" do
    {:ok, first} = start_relay_endpoint(@token)
    {:ok, second} = start_relay_endpoint(@token)
    assert :ok = Endpoint.await_online(first, 10_000)
    assert :ok = Endpoint.await_online(second, 10_000)
    assert {:ok, first_id} = Endpoint.id(first)
    assert {:ok, second_id} = Endpoint.id(second)
    refute first_id == second_id
    assert {:ok, %{direct_ip?: false, bound_sockets: []}} = Endpoint.status(first)
    assert {:ok, second_addr} = Endpoint.addr(second)
    assert second_addr.ip_addrs == []
    assert second_addr.relay_urls == ["http://127.0.0.1:3340/"]

    accept = Task.async(fn -> Endpoint.accept(second, timeout: 10_000) end)
    {:ok, outgoing} = Endpoint.connect(first, second_addr, @alpn, timeout: 10_000)
    {:ok, incoming} = Task.await(accept, 11_000)
    assert {:ok, %{kind: :relay}} = Connection.path(outgoing)

    payload = :binary.copy(<<1, 2, 3, 4>>, 512 * 1_024)
    {:ok, sender} = Connection.open_uni(outgoing)
    receive_stream = Task.async(fn -> Connection.accept_uni(incoming, timeout: 10_000) end)

    send_task =
      Task.async(fn ->
        :ok = Stream.send(sender, payload, chunk_size: 32 * 1_024, timeout: 15_000)
        Stream.finish(sender)
      end)

    {:ok, receiver} = Task.await(receive_stream, 11_000)

    recv_task =
      Task.async(fn ->
        Stream.recv_to_end(receiver, byte_size(payload), timeout: 15_000)
      end)

    assert :ok = Task.await(send_task, 16_000)
    assert {:ok, ^payload} = Task.await(recv_task, 16_000)

    cleanup([sender, receiver], [outgoing, incoming], [first, second])
  end

  test "wrong and missing relay tokens fail without disclosure" do
    output =
      capture_log(fn ->
        for token <- ["wrong-private-relay-token", nil] do
          assert {:ok, endpoint} = start_relay_endpoint(token)

          assert {:error, %Error{category: :timeout, operation: :endpoint_online} = error} =
                   Endpoint.await_online(endpoint, 300)

          if token do
            refute inspect(error) =~ token
            refute inspect(Endpoint.status(endpoint)) =~ token
          end

          Endpoint.close(endpoint)
        end
      end)

    refute output =~ "wrong-private-relay-token"
    refute output =~ @token
  end

  @tag :multi_beam
  test "separate BEAM VMs use Iroh as payload path and dev_cluster only as control plane" do
    :ok = DevCluster.start_distribution()
    {:ok, cluster} = DevCluster.start_link(2, applications: [:iroh_beam], hidden: true)

    on_exit(fn ->
      if Process.alive?(cluster), do: DevCluster.stop(cluster)
    end)

    {:ok, [sender_node, receiver_node]} = DevCluster.nodes(cluster)
    options = relay_options(@token)
    {:ok, sender} = :erpc.call(sender_node, MultiBeamHelper, :start_endpoint, [options])
    {:ok, receiver} = :erpc.call(receiver_node, MultiBeamHelper, :start_endpoint, [options])
    refute sender.id == receiver.id
    assert sender.addr.ip_addrs == []
    assert receiver.addr.ip_addrs == []

    size = 2 * 1_024 * 1_024

    receive_task =
      Task.async(fn ->
        :erpc.call(
          receiver_node,
          MultiBeamHelper,
          :receive_payload,
          [receiver.owner, @alpn, size],
          25_000
        )
      end)

    assert {:ok, sent} =
             :erpc.call(
               sender_node,
               MultiBeamHelper,
               :send_payload,
               [sender.owner, receiver.addr, @alpn, size],
               25_000
             )

    assert {:ok, received} = Task.await(receive_task, 26_000)
    assert sent.bytes == size
    assert received.bytes == size
    assert sent.hash == received.hash
    assert sent.path.kind == :relay
    assert received.path.kind == :relay

    assert :ok = :erpc.call(sender_node, MultiBeamHelper, :stop_endpoint, [sender.owner])
    assert :ok = :erpc.call(receiver_node, MultiBeamHelper, :stop_endpoint, [receiver.owner])
    assert :ok = DevCluster.stop(cluster)
  end

  test "relay and endpoint restart require explicit application reconnect" do
    {:ok, first} = start_relay_endpoint(@token)
    assert :ok = Endpoint.await_online(first, 10_000)
    assert :ok = Endpoint.close(first)

    {output, status} =
      System.cmd("docker", ["compose", "restart", "iroh-relay"], stderr_to_stdout: true)

    assert status == 0, output
    assert_eventually(&relay_ready?/0, 15_000)

    {:ok, sender} = start_relay_endpoint(@token)
    {:ok, receiver} = start_relay_endpoint(@token)
    assert :ok = Endpoint.await_online(sender, 10_000)
    assert :ok = Endpoint.await_online(receiver, 10_000)
    {:ok, receiver_addr} = Endpoint.addr(receiver)

    accept = Task.async(fn -> Endpoint.accept(receiver, timeout: 10_000) end)
    assert {:ok, outgoing} = Endpoint.connect(sender, receiver_addr, @alpn, timeout: 10_000)
    assert {:ok, incoming} = Task.await(accept, 11_000)
    assert {:ok, %{kind: :relay}} = Connection.path(outgoing)

    cleanup([], [outgoing, incoming], [sender, receiver])
  end

  defp relay_options(token) do
    {:ok, relay} = Relay.new(@relay_url, if(token, do: [token: token], else: []))

    [
      alpns: [@alpn],
      network: {:custom, [relay]},
      direct_ip: false,
      startup_timeout: 10_000,
      shutdown_timeout: 5_000
    ]
  end

  defp start_relay_endpoint(token), do: Endpoint.start_link(relay_options(token))

  defp relay_ready? do
    case :gen_tcp.connect(~c"127.0.0.1", 3340, [:binary, active: false], 1_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  defp cleanup(streams, connections, endpoints) do
    Enum.each(streams, &Stream.abort/1)
    Enum.each(connections, &Connection.close/1)
    Enum.each(endpoints, &Endpoint.close/1)
  end
end
