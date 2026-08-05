defmodule IrohBeam.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/mindreframer/iroh_beam"

  def project do
    [
      app: :iroh_beam,
      version: @version,
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description: "Embedded Iroh transport primitives for Elixir",
      source_url: @source_url,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:crypto, :logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:rustler, "== 0.38.0", optional: true, runtime: false},
      {:rustler_precompiled, "== 0.8.4"},
      {:telemetry, "== 1.4.2"},
      {:ex_doc, "== 0.40.3", only: :dev, runtime: false}
    ]
  end
end
