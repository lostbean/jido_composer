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
      {:req_cassette, "~> 0.5.2", only: :test},

      # Observability (test only — livebooks install their own deps via Mix.install)
      {:agent_obs, "~> 0.1.4", only: :test},
      {:opentelemetry, "~> 1.3", only: :test},
      {:opentelemetry_api, "~> 1.2", only: :test}
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
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/lostbean/jido_composer"},
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE usage-rules.md)
    ]
  end

  defp docs do
    [
      main: "Jido.Composer",
      nest_modules_by_prefix: [
        Jido.Composer.Node,
        Jido.Composer.Workflow,
        Jido.Composer.Orchestrator,
        Jido.Composer.Directive,
        Jido.Composer.HITL
      ],
      groups_for_modules: [
        Core: [
          Jido.Composer,
          Jido.Composer.Node,
          Jido.Composer.Context,
          Jido.Composer.NodeIO,
          Jido.Composer.Error
        ],
        Workflow: [
          Jido.Composer.Workflow,
          Jido.Composer.Workflow.DSL,
          Jido.Composer.Workflow.Machine,
          Jido.Composer.Workflow.Strategy
        ],
        Orchestrator: [
          Jido.Composer.Orchestrator,
          Jido.Composer.Orchestrator.DSL,
          Jido.Composer.Orchestrator.Strategy,
          Jido.Composer.Orchestrator.Configure,
          Jido.Composer.Orchestrator.AgentTool,
          Jido.Composer.Orchestrator.LLMAction
        ],
        Nodes: [
          Jido.Composer.Node.ActionNode,
          Jido.Composer.Node.AgentNode,
          Jido.Composer.Node.FanOutNode,
          Jido.Composer.Node.HumanNode
        ],
        "Suspension & HITL": [
          Jido.Composer.Suspension,
          Jido.Composer.Resume,
          Jido.Composer.Checkpoint,
          Jido.Composer.ChildRef,
          Jido.Composer.HITL.ApprovalRequest,
          Jido.Composer.HITL.ApprovalResponse
        ],
        Directives: [
          Jido.Composer.Directive.Suspend,
          Jido.Composer.Directive.SuspendForHuman,
          Jido.Composer.Directive.FanOutBranch,
          Jido.Composer.Directive.CheckpointAndStop
        ]
      ],
      extras: [
        "README.md",
        # Guides
        "guides/getting-started.md",
        "guides/workflows.md",
        "guides/orchestrators.md",
        "guides/composition.md",
        "guides/hitl.md",
        "guides/observability.md",
        "guides/testing.md",
        "guides/composer-vs-jido-ai.md",
        # Livebooks
        "livebooks/01_etl_pipeline.livemd",
        "livebooks/02_branching_and_parallel.livemd",
        "livebooks/03_approval_workflow.livemd",
        "livebooks/04_llm_orchestrator.livemd",
        "livebooks/05_multi_agent_pipeline.livemd",
        "livebooks/06_observability.livemd",
        "livebooks/07_jido_ai_bridge.livemd"
      ],
      groups_for_extras: [
        Guides: [
          "guides/getting-started.md",
          "guides/workflows.md",
          "guides/orchestrators.md",
          "guides/composition.md",
          "guides/hitl.md",
          "guides/observability.md",
          "guides/testing.md",
          "guides/composer-vs-jido-ai.md"
        ],
        Livebooks: [
          "livebooks/01_etl_pipeline.livemd",
          "livebooks/02_branching_and_parallel.livemd",
          "livebooks/03_approval_workflow.livemd",
          "livebooks/04_llm_orchestrator.livemd",
          "livebooks/05_multi_agent_pipeline.livemd",
          "livebooks/06_observability.livemd",
          "livebooks/07_jido_ai_bridge.livemd"
        ]
      ],
      before_closing_body_tag: &before_closing_body_tag/1
    ]
  end

  defp before_closing_body_tag(:html) do
    """
    <script defer src="https://cdn.jsdelivr.net/npm/mermaid@10.2.3/dist/mermaid.min.js"></script>
    <script>
      let initialized = false;

      window.addEventListener("exdoc:loaded", () => {
        if (!initialized) {
          mermaid.initialize({
            startOnLoad: false,
            theme: document.body.className.includes("dark") ? "dark" : "default"
          });
          initialized = true;
        }

        let id = 0;
        for (const codeEl of document.querySelectorAll("pre code.mermaid")) {
          const preEl = codeEl.parentElement;
          const graphDefinition = codeEl.textContent;
          const graphEl = document.createElement("div");
          const graphId = "mermaid-graph-" + id++;
          mermaid.render(graphId, graphDefinition).then(({svg, bindFunctions}) => {
            graphEl.innerHTML = svg;
            bindFunctions?.(graphEl);
            preEl.insertAdjacentElement("afterend", graphEl);
            preEl.remove();
          });
        }
      });
    </script>
    """
  end

  defp before_closing_body_tag(:epub), do: ""
end
