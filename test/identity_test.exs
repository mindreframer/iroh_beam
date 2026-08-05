defmodule IrohBeam.IdentityTest do
  use IrohBeam.FixtureCase, async: false

  import Bitwise
  import ExUnit.CaptureLog

  alias IrohBeam.{EndpointAddr, EndpointId, EndpointTicket, Error, SecretKey}

  @upstream_id "ae58ff8833241ac82d6ff7611046ed67b5072d142c588d0063e942d9a75502b6"
  @known_secret :binary.copy(<<0x42>>, 32)

  test "generated keys are independent and derive stable public IDs" do
    assert {:ok, first} = SecretKey.generate()
    assert {:ok, second} = SecretKey.generate()
    assert {:ok, first_id} = SecretKey.endpoint_id(first)
    assert {:ok, first_id_again} = SecretKey.endpoint_id(first)
    assert {:ok, second_id} = SecretKey.endpoint_id(second)

    assert first_id == first_id_again
    refute first_id == second_id
    assert byte_size(EndpointId.to_bytes(first_id)) == 32
    assert String.length(to_string(first_id)) == 64
  end

  test "explicit key import and export round-trip while inspection stays redacted" do
    assert {:ok, secret_key} = SecretKey.from_bytes(@known_secret)
    assert {:ok, @known_secret} = SecretKey.export(secret_key)
    assert inspect(secret_key) == "#IrohBeam.SecretKey<redacted>"
    refute inspect(secret_key) =~ Base.encode16(@known_secret, case: :lower)
  end

  test "endpoint ID upstream text and byte vectors round-trip" do
    expected_bytes = Base.decode16!(@upstream_id, case: :lower)

    assert {:ok, endpoint_id} = EndpointId.parse(@upstream_id)
    assert EndpointId.to_bytes(endpoint_id) == expected_bytes
    assert to_string(endpoint_id) == @upstream_id
    assert EndpointId.short(endpoint_id) == "ae58ff8833"
    assert {:ok, ^endpoint_id} = EndpointId.from_bytes(expected_bytes)
    assert EndpointId.parse!(@upstream_id) == endpoint_id
  end

  test "malformed identity values return stable validation errors" do
    assert {:error, %Error{category: :invalid_argument, operation: :secret_key_import}} =
             SecretKey.from_bytes(<<1, 2>>)

    assert {:error, %Error{category: :invalid_argument, operation: :endpoint_id}} =
             EndpointId.parse("not-an-endpoint")

    assert {:error, %Error{category: :invalid_argument, operation: :endpoint_id}} =
             EndpointId.from_bytes(<<0>>)
  end

  test "endpoint addresses normalize IPv4, IPv6, ordering, and duplicates" do
    endpoint_id = EndpointId.parse!(@upstream_id)

    assert {:ok, addr} =
             EndpointAddr.new(endpoint_id,
               relay_urls: ["https://relay.example", "https://relay.example/"],
               ip_addrs: ["[::1]:443", "127.0.0.1:80", "127.0.0.1:80"]
             )

    assert addr.id == endpoint_id
    assert addr.relay_urls == ["https://relay.example/"]
    assert addr.ip_addrs == ["127.0.0.1:80", "[::1]:443"]

    assert {:ok, id_only} = EndpointAddr.new(endpoint_id)
    assert id_only.relay_urls == []
    assert id_only.ip_addrs == []
  end

  test "endpoint addresses reject invalid relay and socket values" do
    endpoint_id = EndpointId.parse!(@upstream_id)

    assert {:error, %Error{category: :invalid_argument, operation: :endpoint_addr}} =
             EndpointAddr.new(endpoint_id, relay_urls: ["file:///tmp/relay"])

    assert {:error, %Error{category: :invalid_argument, operation: :endpoint_addr}} =
             EndpointAddr.new(endpoint_id, relay_urls: ["https://user:secret@example.com"])

    assert {:error, %Error{category: :invalid_argument, operation: :endpoint_addr}} =
             EndpointAddr.new(endpoint_id, ip_addrs: ["127.0.0.1"])
  end

  test "standard endpoint ticket matches the upstream wire vector" do
    endpoint_id = EndpointId.parse!(@upstream_id)

    assert {:ok, addr} =
             EndpointAddr.new(endpoint_id,
               relay_urls: ["http://derp.me./"],
               ip_addrs: ["127.0.0.1:1024"]
             )

    assert {:ok, ticket} = EndpointTicket.new(addr)

    expected =
      Base.decode16!(
        "00" <>
          @upstream_id <>
          "02" <>
          "00" <>
          "10" <>
          "687474703a2f2f646572702e6d652e2f" <>
          "01" <>
          "00" <>
          "7f0000018008",
        case: :lower
      )

    assert EndpointTicket.to_bytes(ticket) == expected
    assert String.starts_with?(to_string(ticket), "endpoint")
    assert {:ok, ^ticket} = EndpointTicket.parse(to_string(ticket))
    assert {:ok, ^ticket} = EndpointTicket.from_bytes(expected)
  end

  test "ticket validation is bounded and reports malformed inputs" do
    assert {:error, %Error{category: :invalid_argument, operation: :endpoint_ticket}} =
             EndpointTicket.parse("wrong-kind")

    assert {:error, %Error{category: :invalid_argument, operation: :endpoint_ticket}} =
             EndpointTicket.from_bytes(:binary.copy(<<0>>, 65 * 1_024))
  end

  test "load_or_create persists one identity across restarts and concurrent creators", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join([tmp_dir, "identities-λ", "endpoint.identity"])

    parent = self()

    creators =
      for _index <- 1..16 do
        Task.async(fn ->
          send(parent, {:creator_ready, self()})

          receive do
            :create_identity -> :ok
          end

          {:ok, key} = SecretKey.load_or_create(path)
          {:ok, id} = SecretKey.endpoint_id(key)
          id
        end)
      end

    creator_pids =
      for _index <- 1..16 do
        assert_receive {:creator_ready, creator_pid}
        creator_pid
      end

    Enum.each(creator_pids, &send(&1, :create_identity))
    ids = Enum.map(creators, &Task.await(&1, 5_000))

    assert length(Enum.uniq(ids)) == 1
    assert byte_size(File.read!(path)) == 32

    assert {:ok, restarted_key} = SecretKey.load_or_create(path)
    assert {:ok, restarted_id} = SecretKey.endpoint_id(restarted_key)
    assert restarted_id == hd(ids)

    if match?({:unix, _}, :os.type()) do
      mode = File.stat!(path).mode &&& 0o777
      assert mode == 0o600
    end
  end

  test "corrupt identity files fail without replacement", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "corrupt.identity")
    corrupt = <<1, 2, 3, 4>>
    File.write!(path, corrupt)

    assert {:error, %Error{category: :invalid_argument, operation: :identity_load}} =
             SecretKey.load_or_create(path)

    assert File.read!(path) == corrupt
  end

  test "known private bytes do not appear in inspection, errors, or logs" do
    secret_hex = Base.encode16(@known_secret, case: :lower)
    {:ok, secret_key} = SecretKey.from_bytes(@known_secret)

    output =
      capture_log(fn ->
        refute inspect(secret_key) =~ secret_hex
        assert {:error, error} = EndpointId.parse(secret_hex <> "00")
        refute Exception.message(error) =~ secret_hex
      end)

    refute output =~ secret_hex
  end
end
