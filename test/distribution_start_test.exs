defmodule IrohBeam.DistributionStartTest do
  use IrohBeam.FixtureCase, async: false

  alias IrohBeam.{Distribution, DistributionProcess, Error}

  test "dynamic startup requires the Iroh protocol init arguments" do
    refute Node.alive?()

    assert {:error, %Error{operation: :distribution_start, message: message}} =
             Distribution.start(
               name: :missing@host,
               identity: :ephemeral,
               network: :direct,
               peers: %{}
             )

    assert message =~ "-proto_dist iroh"
  end

  test "dynamic startup and stop use the early endpoint child without EPMD" do
    unique = System.unique_integer([:positive])

    script = """
    options = [
      name: :\"dynamic#{unique}@host\",
      identity: :ephemeral,
      network: :direct,
      peers: %{},
      accept_timeout: 100
    ]
    {:ok, _pid} = IrohBeam.Distribution.start(options)
    {:ok, status} = IrohBeam.Distribution.status()
    IO.puts(["DIST_READY ", Atom.to_string(Node.self()), " ", to_string(status.ready), " ", to_string(status.configured_peers)])
    :ok = IrohBeam.Distribution.stop()
    IO.puts(["DIST_STOPPED ", to_string(Node.alive?())])
    {:ok, _pid} = IrohBeam.Distribution.start(options)
    IO.puts(["DIST_RESTARTED ", to_string(Node.alive?())])
    :ok = IrohBeam.Distribution.stop()
    """

    {:ok, process} =
      DistributionProcess.start(
        "elixir",
        [
          "--erl",
          "-proto_dist iroh -no_epmd",
          "-S",
          "mix",
          "run",
          "--no-compile",
          "-e",
          script
        ],
        env: [{"MIX_ENV", "test"}]
      )

    assert {:ok, %{status: 0, output: output}} = DistributionProcess.await_exit(process, 15_000)
    assert output =~ "DIST_READY dynamic#{unique}@host true 0"
    assert output =~ "DIST_STOPPED false"
    assert output =~ "DIST_RESTARTED true"
  end

  test "early named startup reads boot-time application environment", %{tmp_dir: tmp_dir} do
    unique = System.unique_integer([:positive])
    node_name = "early#{unique}@local"
    config_base = Path.join(tmp_dir, "sys")

    File.write!(
      config_base <> ".config",
      "[{iroh_beam,[{distribution,[{name,'#{node_name}'},{name_domain,shortnames},{identity,ephemeral},{network,direct},{peers,\#{}}]}]}].\n"
    )

    code_paths =
      Path.wildcard(Path.expand("_build/test/lib/*/ebin"))
      |> Enum.map_join(" ", &"-pa #{&1}")

    erl_args = "#{code_paths} -config #{config_base} -proto_dist iroh -no_epmd"

    script =
      "{:ok, status} = :iroh_dist_endpoint.status(); " <>
        "IO.puts([\"EARLY_READY \", Atom.to_string(Node.self()), \" \", to_string(status.ready)]); " <>
        ":init.stop()"

    {:ok, process} =
      DistributionProcess.start("elixir", [
        "--erl",
        erl_args,
        "--sname",
        node_name,
        "-e",
        script
      ])

    assert {:ok, %{status: 0, output: output}} = DistributionProcess.await_exit(process, 15_000)
    assert output =~ "EARLY_READY #{node_name} true"
  end
end
