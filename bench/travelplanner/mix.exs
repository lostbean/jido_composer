defmodule TravelPlannerBench.MixProject do
  use Mix.Project

  def project do
    [
      app: :travel_planner_bench,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {TravelPlanner.Application, []},
      extra_applications: [:logger, :inets, :ssl]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jido_composer, path: "../..", override: true},
      {:jido, "~> 2.0"},
      {:jido_action, "~> 2.0"},
      {:req_llm, "~> 1.6"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:explorer, "~> 0.10"},
      {:req_cassette, "~> 0.5", only: :test}
    ]
  end
end
