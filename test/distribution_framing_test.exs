defmodule IrohBeam.DistributionFramingTest do
  use ExUnit.Case, async: true

  test "packet-two framing supports bounded iodata and exact length headers" do
    assert {:ok, <<0, 0>>} = :iroh_dist.packet2_frame([])
    assert {:ok, <<0, 5, "hello">>} = :iroh_dist.packet2_frame(["he", ["ll"], ?o])

    payload = :binary.copy(<<0xA5>>, 65_535)
    assert {:ok, <<65_535::16, ^payload::binary>>} = :iroh_dist.packet2_frame(payload)
    assert {:error, :emsgsize} = :iroh_dist.packet2_frame([payload, <<0>>])
  end

  test "packet-two framing does not retain caller iodata structure" do
    part = :binary.copy("x", 1024)
    assert {:ok, frame} = :iroh_dist.packet2_frame([part, [part, part]])
    assert <<3072::16, body::binary>> = frame
    assert body == :binary.copy("x", 3072)
  end
end
