defmodule IrohBeam.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/mindreframer/iroh_beam"
  @authors ["Roman Heinrich <roman.heinrich@gmail.com>"]

  def project do
    [
      app: :iroh_beam,
      version: @version,
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      erlc_options: [:warnings_as_errors],
      start_permanent: Mix.env() == :prod,
      description:
        "Authenticated, bounded Iroh endpoint, connection, stream, datagram, and private-relay transport for Elixir",
      source_url: @source_url,
      homepage_url: @source_url,
      authors: @authors,
      package: package(),
      docs: docs(),
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

  defp package do
    [
      licenses: ["MIT"],
      maintainers: @authors,
      links: %{
        "Source" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      build_tools: ["mix", "cargo"],
      files:
        [
          "lib",
          "src",
          "native/iroh_beam_nif/src",
          "native/iroh_beam_nif/.cargo",
          "native/iroh_beam_nif/Cargo.toml",
          "native/iroh_beam_nif/Cargo.lock",
          "rust-toolchain.toml",
          ".formatter.exs",
          "mix.exs",
          "README.md",
          "LICENSE",
          "NOTICE",
          "CHANGELOG.md",
          "SECURITY.md",
          "docs",
          "examples"
        ] ++ Path.wildcard("checksum-Elixir.IrohBeam.Native.exs")
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        {"README.md", [filename: "readme", title: "IrohBeam"]},
        "CHANGELOG.md",
        "SECURITY.md",
        {"LICENSE", [filename: "license", title: "License"]},
        {"NOTICE", [filename: "notice", title: "Third-party notices"]},
        "docs/identity.md",
        "docs/endpoints.md",
        "docs/connections.md",
        "docs/streams.md",
        "docs/private-relay.md",
        "docs/distribution.md",
        "docs/security.md",
        "docs/troubleshooting.md",
        "docs/telemetry.md",
        {"docs/architecture/0001-embedded-nif.md", [filename: "embedded-nif"]},
        "docs/architecture/0002-native-runtime.md",
        "docs/architecture/0003-stable-iroh-scope.md",
        "docs/architecture/0004-iroh-distribution-carrier.md"
      ],
      source_ref: "v#{@version}",
      source_url: @source_url,
      authors: @authors,
      formatters: ["html"]
    ]
  end

  defp deps do
    [
      {:rustler, "== 0.38.0", optional: true, runtime: false},
      {:rustler_precompiled, "== 0.8.4"},
      {:telemetry, "== 1.4.2"},
      {:dev_cluster, "== 0.1.0", only: :test},
      {:ex_doc, "== 0.40.3", only: :dev, runtime: false}
    ]
  end
end
