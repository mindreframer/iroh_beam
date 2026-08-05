defmodule IrohBeam.DistributionDocumentationTest do
  use ExUnit.Case, async: true

  test "two-machine distribution example remains valid Elixir source" do
    source = File.read!("examples/distribution_two_machine.exs")
    assert {:ok, _ast} = Code.string_to_quoted(source)
    refute source =~ "iroh-beam-local-test-token-not-for-production"
  end

  test "distribution guide states the transport, authorization, and membership boundaries" do
    guide = File.read!("docs/distribution.md")
    assert guide =~ "Iroh supplies"
    assert guide =~ "Erlang cookies remain mandatory"
    assert guide =~ "The carrier is not membership"
    assert guide =~ "-proto_dist iroh -no_epmd"
  end
end
