defmodule IrohBeam.Eventually do
  @moduledoc false

  import ExUnit.Assertions

  def assert_eventually(fun, timeout \\ 1_000) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(fun, deadline)
  end

  defp poll(fun, deadline) do
    if fun.() do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline, "condition did not become true"
      Process.sleep(5)
      poll(fun, deadline)
    end
  end
end
