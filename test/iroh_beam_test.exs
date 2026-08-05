defmodule IrohBeamTest do
  use ExUnit.Case
  doctest IrohBeam

  test "greets the world" do
    assert IrohBeam.hello() == :world
  end
end
