defmodule IrohBeam.DistributionFramingTest do
  use ExUnit.Case, async: true

  test "packet-two framing supports bounded iodata and exact length headers" do
    assert {:ok, <<0, 0>>} = :iroh_dist.packet2_frame([])
    assert {:ok, <<0, 5, "hello">>} = :iroh_dist.packet2_frame(["he", ["ll"], ?o])

    payload = :binary.copy(<<0xA5>>, 65_535)
    assert {:ok, <<65_535::16, ^payload::binary>>} = :iroh_dist.packet2_frame(payload)
    assert {:error, :emsgsize} = :iroh_dist.packet2_frame([payload, <<0>>])
  end

  test "packet-four parser accepts every split and coalesced ticks" do
    frame = <<5::32, "hello", 0::32, 3::32, "bye">>

    for split <- 0..byte_size(frame) do
      <<left::binary-size(^split), right::binary>> = frame
      parser = :iroh_dist_controller.parser_new()
      assert {:ok, first, parser} = :iroh_dist_controller.parser_feed(parser, left, 1024)
      assert {:ok, second, _parser} = :iroh_dist_controller.parser_feed(parser, right, 1024)

      packets = Enum.map(first ++ second, &IO.iodata_to_binary/1)
      assert packets == ["hello", "", "bye"]
    end
  end

  test "packet-four parser bounds incomplete bodies before allocation" do
    parser = :iroh_dist_controller.parser_new()
    assert {:ok, [], parser} = :iroh_dist_controller.parser_feed(parser, <<0, 0>>, 8)
    assert {:ok, [], parser} = :iroh_dist_controller.parser_feed(parser, <<0, 8, "abc">>, 8)

    assert {:ok, [packet], _parser} =
             :iroh_dist_controller.parser_feed(parser, "defgh", 8)

    assert IO.iodata_to_binary(packet) == "abcdefgh"

    assert {:error, {:frame_too_large, 9}} =
             :iroh_dist_controller.parser_feed(
               :iroh_dist_controller.parser_new(),
               <<9::32>>,
               8
             )
  end

  test "packet-two framing does not retain caller iodata structure" do
    part = :binary.copy("x", 1024)
    assert {:ok, frame} = :iroh_dist.packet2_frame([part, [part, part]])
    assert <<3072::16, body::binary>> = frame
    assert body == :binary.copy("x", 3072)
  end
end
