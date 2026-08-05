defmodule IrohBeam.DistributionFoundationTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias IrohBeam.DistributionProcess

  @required_callbacks [
    childspecs: 0,
    listen: 1,
    listen: 2,
    accept: 1,
    accept_connection: 5,
    setup: 5,
    close: 1,
    select: 1,
    address: 0,
    address: 1
  ]

  test "OTP 29 support is centralized and deterministic" do
    assert :ok = :iroh_dist_support.check()
    assert :ok = :iroh_dist_support.check(~c"29")
    assert :ok = :iroh_dist_support.check("29.4")

    assert {:error, {:unsupported_otp, ~c"28", message}} =
             :iroh_dist_support.check(~c"28")

    assert message == ~c"Iroh distribution requires OTP 29.x"
    assert {:error, {:unsupported_otp, :unknown, _}} = :iroh_dist_support.check(:unknown)
  end

  test "creation values stay in OTP's valid non-small range" do
    assert 4 == :iroh_dist_support.new_creation(0)
    assert 5 == :iroh_dist_support.new_creation(1)
    assert 4 == :iroh_dist_support.new_creation(1 <<< 32)
    assert (1 <<< 32) - 1 == :iroh_dist_support.new_creation((1 <<< 32) - 1)

    for _ <- 1..128 do
      creation = :iroh_dist_support.new_creation()
      assert creation >= 4
      assert creation < 1 <<< 32
    end
  end

  test "carrier exports the OTP callbacks and returns an Iroh address" do
    assert {:module, :iroh_dist} = Code.ensure_loaded(:iroh_dist)

    for {function, arity} <- @required_callbacks do
      assert function_exported?(:iroh_dist, function, arity)
    end

    assert {:net_address, :undefined, ~c"example", :iroh, :iroh} =
             :iroh_dist.address(~c"example")

    assert false == :iroh_dist.select(:peer@example)

    assert {:error, :not_started} = :iroh_dist.listen(:local, ~c"example")

    assert :ok = :iroh_dist.close(:unused)
  end

  test "distribution child spec is owned by the carrier" do
    {:ok, [spec]} = :iroh_dist.childspecs()
    assert spec.id == :iroh_dist_endpoint
    assert spec.start == {:iroh_dist_endpoint, :start_link, []}
    assert spec.type == :worker
  end

  test "unimplemented process callbacks terminate promptly" do
    for pid <- [
          :iroh_dist.accept_connection(self(), :unused, :me@host, [], 100),
          :iroh_dist.setup(:peer@host, :normal, :me@host, :shortnames, 100)
        ] do
      monitor = Process.monitor(pid)
      assert_receive {:DOWN, ^monitor, :process, ^pid, reason}, 500
      assert reason in [{:iroh_distribution, :handshake_not_ready}, :noproc]
    end
  end

  test "process harness observes output and exit without distribution" do
    {:ok, process} =
      DistributionProcess.start("elixir", ["-e", "IO.puts(\"IROH_READY\")"])

    assert {:ok, process} = DistributionProcess.await_output(process, "IROH_READY")
    assert {:ok, %{status: 0, output: output}} = DistributionProcess.await_exit(process)
    assert output =~ "IROH_READY"
  end

  test "process harness times out, truncates output, and forcibly cleans a child" do
    script = "IO.write(String.duplicate(\"x\", 4096)); Process.sleep(:infinity)"
    {:ok, process} = DistributionProcess.start("elixir", ["-e", script], max_output: 512)
    assert {:error, :timeout, process} = DistributionProcess.await_output(process, "never", 200)
    assert {:ok, %{status: status, output: output}} = DistributionProcess.stop(process)
    assert is_integer(status)
    assert byte_size(output) <= 512
  end

  test "proto_dist loads from a separate unnamed VM with no EPMD" do
    ebin = Path.expand("_build/test/lib/iroh_beam/ebin")
    erl_args = "-pa #{ebin} -proto_dist iroh -no_epmd"

    {:ok, process} =
      DistributionProcess.start("elixir", [
        "--erl",
        erl_args,
        "-e",
        "IO.puts(inspect(:code.ensure_loaded(:iroh_dist)))"
      ])

    assert {:ok, %{status: 0, output: output}} = DistributionProcess.await_exit(process)
    assert output =~ "{:module, :iroh_dist}"
  end

  test "early named startup fails clearly when boot-time configuration is missing" do
    ebin = Path.expand("_build/test/lib/iroh_beam/ebin")
    erl_args = "-pa #{ebin} -proto_dist iroh -no_epmd"
    name = "foundation#{System.unique_integer([:positive])}@local"

    {:ok, process} =
      DistributionProcess.start("elixir", [
        "--erl",
        erl_args,
        "--sname",
        name,
        "-e",
        "IO.puts(\"unexpected\")"
      ])

    assert {:ok, %{status: status, output: output}} = DistributionProcess.await_exit(process)
    assert status != 0
    assert output =~ "distribution_config"
    assert output =~ "invalid_argument"
  end
end
