defmodule Jido.Composer do
  @moduledoc """
  Composable agent topologies for the Jido ecosystem.

  Two patterns that nest arbitrarily: **Workflow** (deterministic FSM) and
  **Orchestrator** (LLM-driven ReAct loop). Both produce `Jido.Agent` modules
  sharing a uniform Node interface (`context → context`). Human-in-the-loop
  gates and durable checkpoint/resume are first-class.

  ## Quick Start — Workflow

      defmodule MyPipeline do
        use Jido.Composer.Workflow,
          name: "pipeline",
          nodes: %{
            fetch:     FetchAction,
            transform: TransformAction,
            store:     StoreAction
          },
          transitions: %{
            {:fetch, :ok}      => :transform,
            {:transform, :ok}  => :store,
            {:store, :ok}      => :done,
            {:_, :error}       => :failed
          },
          initial: :fetch
      end

      agent = MyPipeline.new()
      {:ok, result} = MyPipeline.run_sync(agent, %{url: "https://example.com"})

  ## Quick Start — Orchestrator

      defmodule MyAssistant do
        use Jido.Composer.Orchestrator,
          name: "assistant",
          model: "anthropic:claude-sonnet-4-20250514",
          nodes: [SearchAction, WriteAction],
          system_prompt: "You help with research and writing."
      end

      agent = MyAssistant.new()
      {:ok, answer} = MyAssistant.query_sync(agent, "Summarize recent news")

  ## Quick Start — Composition

  Orchestrators and workflows are both agents, so they nest naturally:

      defmodule EditorialReview do
        use Jido.Composer.Orchestrator,
          name: "editorial_review",
          model: "anthropic:claude-sonnet-4-20250514",
          nodes: [GrammarCheckAction, FactCheckAction],
          system_prompt: "Review content for grammar and facts."
      end

      defmodule PublishingPipeline do
        use Jido.Composer.Workflow,
          name: "publishing",
          nodes: %{
            fetch:   FetchAction,
            review:  EditorialReview,  # orchestrator as a workflow step
            publish: PublishAction
          },
          transitions: %{
            {:fetch, :ok}    => :review,
            {:review, :ok}   => :publish,
            {:publish, :ok}  => :done,
            {:_, :error}     => :failed
          },
          initial: :fetch
      end

  The DSL detects `EditorialReview` is an agent and wraps it as an
  `AgentNode` automatically.

  ## Control Spectrum

  | Level | Pattern | Example |
  |-------|---------|---------|
  | Fully deterministic | Workflow | ETL pipeline |
  | + human gate | Workflow + HumanNode | Approval workflows |
  | + adaptive step | Workflow containing Orchestrator | Code review pipeline |
  | + deterministic tool | Orchestrator containing Workflow | Customer support |
  | Fully adaptive | Orchestrator | Research agent |

  ## Module Organization

  | Module | Purpose |
  |--------|---------|
  | `Jido.Composer.Workflow` | Deterministic FSM workflow DSL |
  | `Jido.Composer.Orchestrator` | LLM-driven orchestrator DSL |
  | `Jido.Composer.Node` | Uniform `context -> context` behaviour |
  | `Jido.Composer.Node.ActionNode` | Wraps a `Jido.Action` as a node |
  | `Jido.Composer.Node.AgentNode` | Wraps a `Jido.Agent` as a node |
  | `Jido.Composer.Node.FanOutNode` | Parallel branch execution |
  | `Jido.Composer.Node.HumanNode` | Human approval gate |
  | `Jido.Composer.Context` | Layered context (ambient/working/fork) |
  | `Jido.Composer.NodeIO` | Typed output envelope |
  | `Jido.Composer.Suspension` | Generalized pause/resume metadata |
  | `Jido.Composer.Resume` | Resume suspended agents |
  | `Jido.Composer.Checkpoint` | Persistence for long-running flows |

  ## Guides

  - [Composition & Nesting](composition.md)
  - [Human-in-the-Loop](hitl.md)
  - [Getting Started](getting-started.md)
  - [Workflows](workflows.md)
  - [Orchestrators](orchestrators.md)
  - [Observability](observability.md)
  - [Testing](testing.md)
  """
end
