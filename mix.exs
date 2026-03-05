defmodule JidoComposer.MixProject do
  use Mix.Project

  def project do
    [
      app: :jido_composer,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() != :dev,
      aliases: aliases(),
      deps: deps(),
      docs: docs(),
      name: "Jido Composer",
      source_url: "https://github.com/lostbean/jido_composer",
      description: "Composable agent flows via FSM for the Jido ecosystem",
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test, ci: :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Jido ecosystem
      {:jido, "~> 2.0"},
      {:jido_action, "~> 2.0"},
      {:jido_signal, "~> 2.0"},

      # Runtime
      {:zoi, "~> 0.17"},
      {:splode, "~> 0.3.0"},
      {:deep_merge, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:nimble_options, "~> 1.1"},
      {:telemetry, "~> 1.3"},

      # LLM
      {:req_llm, "~> 1.6"},

      # Dev/Test
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: [:dev, :test], runtime: false},
      {:req_cassette, "~> 0.5.2", only: :test}
    ]
  end

  defp aliases do
    [
      # Formatting
      fmt: ["format", "cmd nix fmt"],
      "fmt.check": ["format --check-formatted", "cmd nix fmt -- --fail-on-change"],

      # Linting
      lint: ["lint.credo"],
      "lint.credo": ["credo --min-priority high"],

      # Type checking
      check: ["compile --warnings-as-errors"],

      # Documentation
      "docs.check": ["docs --warnings-as-errors"],

      # Pre-commit quality gate (modifies files)
      precommit: [
        "fmt",
        "docs.check",
        "check",
        "lint",
        "deps.unlock --unused",
        "test --max-failures 10"
      ],

      # CI quality gate (read-only)
      ci: [
        "compile --force",
        "fmt.check",
        "docs.check",
        "check",
        "lint",
        "deps.unlock --check-unused",
        "test --max-failures 10"
      ]
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/lostbean/jido_composer"}
    ]
  end

  defp docs do
    [
      main: "Jido.Composer",
      extras: ["README.md", "PLAN.md"]
    ]
  end
end
