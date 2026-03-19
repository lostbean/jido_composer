# Getting Started

A 5-minute introduction to building composable agent topologies with Jido Composer.

## What Makes Composer Special

Workflows and orchestrators are both `Jido.Agent` modules. Agents are nodes. Nodes compose at any depth — a workflow step can be an orchestrator, an orchestrator tool can be a workflow, and you can nest further. The uniform `context → context` interface makes every node interchangeable regardless of what runs inside it.

Any flow can pause for human input. HumanNode gates in workflows and tool approval gates in orchestrators use the same `ApprovalRequest`/`ApprovalResponse` protocol. The generalized suspension system extends beyond HITL to rate limits, async completions, and custom pause reasons.

Running and suspended flows can be checkpointed to storage and resumed across process restarts — including deeply nested agent hierarchies. PIDs become serializable `ChildRef` structs, and resume is idempotent with top-down child re-spawning.

This guide covers the building blocks. See [Composition & Nesting](composition.md) and [Human-in-the-Loop](hitl.md) for the full picture.

## Prerequisites

- Elixir 1.18+
- The [Jido](https://hexdocs.pm/jido) ecosystem (`jido`, `jido_action`, `jido_signal`)
- For orchestrators: an LLM API key (e.g., Anthropic)

## Installation

Add `jido_composer` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:jido_composer, "~> 0.1.0"}
  ]
end
```

Then fetch:

```bash
mix deps.get
```

## Your First Workflow

Workflows are deterministic FSM pipelines. Each state binds to an action, and transitions are determined by outcomes.

### Step 1: Define Actions

Actions are the building blocks. Each one takes parameters and returns a result:

```elixir
defmodule ExtractAction do
  use Jido.Action,
    name: "extract",
    description: "Extract records from a data source",
    schema: [source: [type: :string, required: true]]

  @impl true
  def run(%{source: source}, _ctx) do
    # In real code, this would fetch from a database or API
    {:ok, %{records: [%{id: 1, name: "Alice"}, %{id: 2, name: "Bob"}], source: source}}
  end
end

defmodule TransformAction do
  use Jido.Action,
    name: "transform",
    description: "Transform extracted records",
    schema: []

  @impl true
  def run(params, _ctx) do
    records = get_in(params, [:extract, :records]) || []
    transformed = Enum.map(records, &Map.put(&1, :processed, true))
    {:ok, %{records: transformed}}
  end
end

defmodule LoadAction do
  use Jido.Action,
    name: "load",
    description: "Load records into storage",
    schema: []

  @impl true
  def run(params, _ctx) do
    records = get_in(params, [:transform, :records]) || []
    {:ok, %{loaded: length(records), status: "complete"}}
  end
end
```

### Step 2: Define the Workflow

Wire the actions into an FSM with states and transitions:

```elixir
defmodule ETLPipeline do
  use Jido.Composer.Workflow,
    name: "etl_pipeline",
    nodes: %{
      extract:   ExtractAction,
      transform: TransformAction,
      load:      LoadAction
    },
    transitions: %{
      {:extract, :ok}   => :transform,
      {:transform, :ok} => :load,
      {:load, :ok}      => :done,
      {:_, :error}      => :failed
    },
    initial: :extract
end
```

No `terminal_states` or `success_states` are specified, so the convention defaults apply: `:done` and `:failed` are terminal states, with `:done` as the success state. This generates a full `Jido.Agent` module with `run/2` and `run_sync/2` functions. Here's what the FSM looks like:

```mermaid
stateDiagram-v2
    [*] --> extract
    extract --> transform : ok
    transform --> load : ok
    load --> done : ok
    extract --> failed : error
    transform --> failed : error
    load --> failed : error
    done --> [*]
    failed --> [*]
```

### Step 3: Run It

```elixir
agent = ETLPipeline.new()
{:ok, result} = ETLPipeline.run_sync(agent, %{source: "customer_db"})

# Result is a flat map with results scoped under each state name:
result[:extract][:records]    #=> [%{id: 1, name: "Alice"}, %{id: 2, name: "Bob"}]
result[:transform][:records]  #=> [%{id: 1, name: "Alice", processed: true}, ...]
result[:load][:loaded]        #=> 2
result[:source]               #=> "customer_db" (initial params preserved)
```

Each action's output is scoped under its state name in the context, preventing key collisions and letting downstream actions read upstream results.

## Your First Orchestrator

Orchestrators use an LLM to dynamically choose which tools to invoke via a ReAct loop.

```elixir
defmodule MathAssistant do
  use Jido.Composer.Orchestrator,
    name: "math_assistant",
    model: "anthropic:claude-sonnet-4-20250514",
    nodes: [AddAction, MultiplyAction],
    system_prompt: "You are a math assistant. Use the available tools to compute answers."
end
```

```elixir
agent = MathAssistant.new()
{:ok, _agent, answer} = MathAssistant.query_sync(agent, "What is 5 + 3?")
# answer => "5 + 3 = 8" (LLM's natural language response after using the add tool)
```

The orchestrator automatically:

1. Sends the query to the LLM with available tools
2. Executes any tool calls the LLM makes
3. Feeds results back to the LLM
4. Repeats until the LLM provides a final answer

## Composing Them Together

The `MathAssistant` orchestrator you just defined is a `Jido.Agent` — which means it can be used as a workflow node. Here it becomes one step in a larger pipeline:

```elixir
defmodule MathPipeline do
  use Jido.Composer.Workflow,
    name: "math_pipeline",
    nodes: %{
      parse:     ParseInputAction,
      compute:   MathAssistant,    # orchestrator as a workflow step
      format:    FormatResultAction
    },
    transitions: %{
      {:parse, :ok}   => :compute,
      {:compute, :ok} => :format,
      {:format, :ok}  => :done,
      {:_, :error}    => :failed
    },
    initial: :parse
end

agent = MathPipeline.new()
{:ok, result} = MathPipeline.run_sync(agent, %{input: "what is 5 + 3?"})
```

```mermaid
flowchart LR
    Parse[parse] --> Compute[compute: MathAssistant]
    Compute --> Format[format]
    subgraph Compute[compute: MathAssistant]
        LLM[LLM ReAct Loop] -->|tool call| Add[AddAction]
    end
```

The DSL detects that `MathAssistant` is an agent and wraps it as an `AgentNode` automatically. The orchestrator runs its full ReAct loop inside the workflow step, and the result merges into the pipeline context under the `:compute` key.

This works in the other direction too — list a workflow module in an orchestrator's `nodes` and the LLM can invoke it as a tool. See [Composition & Nesting](composition.md) for all patterns.

## Key Concepts

| Term                | Description                                                                                                                                        |
| ------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Node**            | The uniform `context -> context` interface. Actions, agents, fan-out branches, and human gates are all nodes.                                      |
| **Context**         | Accumulates results across states. Each node's output is scoped under its state/tool name via deep merge.                                          |
| **Directive**       | A side-effect description emitted by strategies. `run_sync` and `query_sync` handle them automatically.                                            |
| **Outcome**         | An atom (`:ok`, `:error`, or custom) returned by a node that determines which transition fires.                                                    |
| **Transition**      | A `{state, outcome} => next_state` mapping. Use `{:_, :error}` as a wildcard catch-all.                                                            |
| **Terminal State**  | A state that ends the flow. Convention defaults: `:done` (success) and `:failed`. Custom sets require both `terminal_states` and `success_states`. |
| **Suspension**      | A pause in execution — for human input, rate limits, async jobs, or custom reasons.                                                                |
| **Deep Merge**      | How node results accumulate: maps merge recursively, scoped under the node's state name to prevent key collisions.                                 |
| **Ambient Context** | Read-only keys visible to all nodes. Configured via the `ambient:` DSL option.                                                                     |
| **Fork Functions**  | MFA tuples that transform ambient values at agent boundaries when nesting.                                                                         |

## Next Steps

- [Composition & Nesting](composition.md) — Nesting patterns, context flow, control spectrum
- [Human-in-the-Loop](hitl.md) — HumanNode, approval gates, suspension, persistence
- [Workflows Guide](workflows.md) — All DSL options, fan-out, custom outcomes, compile-time validation
- [Orchestrators Guide](orchestrators.md) — LLM config, tool approval gates, streaming, backpressure
- [Observability](observability.md) — OTel spans, tracer setup, span hierarchy
- [Testing](testing.md) — ReqCassette, LLMStub, test layers
