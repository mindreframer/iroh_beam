defmodule IrohBeam.FixtureCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  setup context do
    unique = System.unique_integer([:positive, :monotonic])
    tmp_dir = Path.join(System.tmp_dir!(), "iroh-beam-#{context.module}-#{unique}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end
end
