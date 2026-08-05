defmodule IrohBeam.DistributionConfigTest do
  use IrohBeam.FixtureCase, async: false

  alias IrohBeam.{Distribution.Config, EndpointAddr, Error, Identity, Relay}

  setup do
    Config.uninstall()
    on_exit(&Config.uninstall/0)
    :ok
  end

  test "normalizes exact typed and tagged peers", %{tmp_dir: tmp_dir} do
    {:ok, peer_key} = Identity.generate()
    {:ok, peer_id} = IrohBeam.SecretKey.endpoint_id(peer_key)
    {:ok, peer_addr} = EndpointAddr.new(peer_id, ip_addrs: ["127.0.0.1:44001"])

    options = [
      name: :local@host,
      identity: {:file, Path.join(tmp_dir, "local.key")},
      network: :direct,
      peers: %{
        :id@host => {:id, to_string(peer_id)},
        :addr@host => peer_addr
      }
    ]

    # One endpoint identity cannot represent two node names.
    assert {:error, %Error{message: message}} = Config.validate(options)
    assert message =~ "unique"

    assert {:ok, config} =
             Config.validate(Keyword.put(options, :peers, %{:addr@host => {:addr, peer_addr}}))

    assert {:ok, %{id: ^peer_id, target: ^peer_addr}} = Config.resolve(config, :addr@host)
    assert {:ok, :addr@host} = Config.authorize_id(config, peer_id)
    assert [:addr@host] == Config.allowed_nodes(config)
    assert {:error, :unknown_peer} = Config.resolve(config, :missing@host)
  end

  test "rejects invalid names, unknown keys, targets, limits, and local peers", %{
    tmp_dir: tmp_dir
  } do
    base = [
      name: :local@host,
      identity: {:file, Path.join(tmp_dir, "local.key")},
      network: :direct,
      peers: %{}
    ]

    invalid = [
      Keyword.put(base, :name, :local),
      Keyword.put(base, :name_domain, :longnames),
      Keyword.put(base, :unknown, true),
      Keyword.put(base, :peers, %{:peer@host => {:id, "invalid"}}),
      Keyword.put(base, :peers, %{:local@host => {:id, String.duplicate("00", 32)}}),
      Keyword.put(base, :receive_chunk, 0),
      Keyword.merge(base, receive_chunk: 2048, max_frame: 1024),
      Keyword.merge(base, direct_ip: false, bind: ["127.0.0.1:0"])
    ]

    for options <- invalid do
      assert {:error, %Error{category: :invalid_argument}} = Config.validate(options)
    end
  end

  test "safe configuration redacts relay tokens and serialized targets", %{tmp_dir: tmp_dir} do
    {:ok, peer_key} = Identity.generate()
    {:ok, peer_id} = IrohBeam.SecretKey.endpoint_id(peer_key)
    token = "distribution-token-sentinel"
    {:ok, relay} = Relay.new("http://127.0.0.1:3340", token: token)

    assert {:ok, config} =
             Config.validate(
               name: :local@host,
               identity: {:file, Path.join(tmp_dir, "local.key")},
               network: {:custom, [relay]},
               direct_ip: false,
               peers: %{:peer@host => {:id, to_string(peer_id)}}
             )

    safe = Config.safe(config)
    inspected = inspect(safe)
    refute inspected =~ token
    refute inspected =~ to_string(peer_id)
    assert {:custom, [%{token?: true}]} = safe.network
  end

  test "install is immutable until explicitly uninstalled", %{tmp_dir: tmp_dir} do
    assert {:ok, config} =
             Config.validate(
               name: :local@host,
               identity: {:file, Path.join(tmp_dir, "local.key")},
               network: :direct,
               peers: %{}
             )

    assert :ok = Config.install(config)
    assert config == Config.get()
    assert {:error, %Error{category: :already_started}} = Config.install(config)
    assert :ok = Config.uninstall()
    assert :undefined == Config.get()
  end
end
