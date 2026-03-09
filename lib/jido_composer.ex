defmodule Jido.Composer do
  @moduledoc """
  Composable agent flows for the Jido ecosystem.

  Jido Composer provides two composition patterns that nest arbitrarily:

  - **`Jido.Composer.Workflow`** — Deterministic FSM pipeline. Each state binds to
    an action or sub-agent. Transitions are fully determined by outcomes.
  - **`Jido.Composer.Orchestrator`** — LLM-driven dynamic composition. An agent
    uses a ReAct loop to freely invoke available tools at runtime.

  Both produce standard `Jido.Agent` modules and share a uniform
  `Jido.Composer.Node` interface (`context -> context`).

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

  - [Getting Started](getting-started.md)
  - [Workflows](workflows.md)
  - [Orchestrators](orchestrators.md)
  - [Composition & Nesting](composition.md)
  - [Human-in-the-Loop](hitl.md)
  - [Observability](observability.md)
  - [Testing](testing.md)
  """
end
