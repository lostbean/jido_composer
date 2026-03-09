# Composition

Workflows and orchestrators both produce `Jido.Agent` modules. Agents are Nodes. Nodes compose. This recursive property means you can nest arbitrarily: a workflow can contain an orchestrator as a node, and an orchestrator can invoke a workflow as a tool.

## Control Spectrum

Choose the right composition pattern based on how much decision-making you want the system to make:

| Level                         | Pattern                                    | Example                                           |
| ----------------------------- | ------------------------------------------ | ------------------------------------------------- |
| Fully deterministic           | Workflow with ActionNodes                  | ETL pipeline                                      |
| Deterministic with delegation | Workflow with AgentNodes                   | Pipeline that delegates one step to a sub-agent   |
| Structured adaptive           | Workflow wrapping Orchestrator at one step | Content pipeline with LLM-driven editorial review |
| Guided adaptive               | Orchestrator with constrained tools        | Math assistant with specific tool set             |
| Fully adaptive                | Orchestrator wrapping Orchestrators        | Coordinator delegating to specialist agents       |

## Nesting Patterns

### Workflow Inside Orchestrator

The LLM can invoke a workflow as a tool. List the workflow module in `nodes`:

```elixir
defmodule ETLWorkflow do
  use Jido.Composer.Workflow,
    name: "etl_pipeline",
    description: "Run an ETL pipeline on a data source",
    nodes: %{extract: ExtractAction, transform: TransformAction, load: LoadAction},
    transitions: %{
      {:extract, :ok} => :transform,
      {:transform, :ok} => :load,
      {:load, :ok} => :done,
      {:_, :error} => :failed
    },
    initial: :extract
end

defmodule Coordinator do
  use Jido.Composer.Orchestrator,
    name: "coordinator",
    model: "anthropic:claude-sonnet-4-20250514",
    nodes: [ETLWorkflow, AnalyzeAction],
    system_prompt: "You coordinate data pipelines and analysis."
end
```

When the LLM calls the `etl_pipeline` tool, the workflow runs synchronously via `run_sync/2` and its result is fed back to the LLM conversation.

```mermaid
flowchart TD
    subgraph Orchestrator
        LLM[LLM ReAct Loop]
        LLM -->|tool call| WF[ETL Workflow]
        LLM -->|tool call| A1[Analyze Action]
    end
    subgraph WF[ETL Workflow]
        S1[extract] --> S2[transform] --> S3[load]
    end
```

### Orchestrator Inside Workflow

Use an orchestrator module as a workflow node. It's detected as `AgentNode` automatically:

```elixir
defmodule EditorialReview do
  use Jido.Composer.Orchestrator,
    name: "editorial_review",
    model: "anthropic:claude-sonnet-4-20250514",
    nodes: [GrammarCheckAction, FactCheckAction, StyleGuideAction],
    system_prompt: "Review the content for grammar, facts, and style."
end

defmodule PublishingPipeline do
  use Jido.Composer.Workflow,
    name: "publishing",
    nodes: %{
      fetch: FetchAction,
      review: EditorialReview,  # orchestrator as workflow node
      publish: PublishAction,
      distribute: DistributeAction
    },
    transitions: %{
      {:fetch, :ok} => :review,
      {:review, :ok} => :publish,
      {:publish, :ok} => :distribute,
      {:distribute, :ok} => :done,
      {:_, :error} => :failed
    },
    initial: :fetch
end
```

### Multi-Level Nesting

You can nest three or more levels deep. A common pattern is an orchestrator that delegates to workflows, where one workflow step is itself an orchestrator:

```elixir
# Level 3: Diagnostic orchestrator (innermost)
defmodule DiagnosticOrchestrator do
  use Jido.Composer.Orchestrator,
    name: "diagnostics",
    model: "anthropic:claude-sonnet-4-20250514",
    nodes: [PingAction, TracerouteAction, LogSearchAction],
    system_prompt: "Diagnose technical issues using available tools."
end

# Level 2: Technical support workflow (contains orchestrator)
defmodule TechnicalSupportWorkflow do
  use Jido.Composer.Workflow,
    name: "tech_support",
    nodes: %{
      gather_info: GatherInfoAction,
      diagnose: DiagnosticOrchestrator,  # nested orchestrator
      resolve: ResolveAction
    },
    transitions: %{
      {:gather_info, :ok} => :diagnose,
      {:diagnose, :ok} => :resolve,
      {:resolve, :ok} => :done,
      {:_, :error} => :failed
    },
    initial: :gather_info
end

# Level 1: Support triage orchestrator (outermost)
defmodule SupportTriage do
  use Jido.Composer.Orchestrator,
    name: "triage",
    model: "anthropic:claude-sonnet-4-20250514",
    nodes: [TechnicalSupportWorkflow, BillingSupportWorkflow, AccountWorkflow],
    system_prompt: "Route support tickets to the right workflow."
end
```

### Parallel Sub-Agents with FanOutNode

Run multiple agents or actions in parallel within a workflow:

```elixir
{:ok, due_diligence} = Jido.Composer.Node.FanOutNode.new(
  name: "due_diligence",
  branches: [
    financial: FinancialReviewAgent,
    legal: LegalReviewAgent,
    background: BackgroundCheckAction
  ],
  merge: :deep_merge,
  on_error: :collect_partial,
  max_concurrency: 3,
  timeout: 60_000
)

defmodule AcquisitionPipeline do
  use Jido.Composer.Workflow,
    name: "acquisition",
    nodes: %{
      intake: IntakeAction,
      review: due_diligence,  # parallel branches
      decision: DecisionAction
    },
    transitions: %{
      {:intake, :ok} => :review,
      {:review, :ok} => :decision,
      {:decision, :ok} => :done,
      {:_, :error} => :failed
    },
    initial: :intake
end
```

Branch results are merged under their respective keys:

```elixir
# After review completes:
# context[:review][:financial] => %{score: 85, ...}
# context[:review][:legal] => %{risk: :low, ...}
# context[:review][:background] => %{clear: true, ...}
```

## Context Flow Across Boundaries

When nesting, context flows through three layers:

| Layer        | Mutability | Scope                                                    |
| ------------ | ---------- | -------------------------------------------------------- |
| **Ambient**  | Read-only  | Visible to all nodes via `params[Context.ambient_key()]` |
| **Working**  | Mutable    | Scoped per node under state/tool name                    |
| **Fork Fns** | Transform  | Applied at agent boundaries when nesting                 |

At each agent boundary:

1. The parent's ambient context is forked for the child via `fork_fns`
2. The child receives transformed ambient data + its own working state
3. Results bubble up from the child, scoped under the node's state name in the parent

### Fork Functions

Fork functions transform ambient values at composition boundaries. They're MFA tuples applied when spawning child agents:

```elixir
use Jido.Composer.Workflow,
  ambient: [:api_key, :config, :depth, :trace],
  fork_fns: %{
    depth: {__MODULE__, :increment_depth, []},
    trace: {__MODULE__, :append_trace, [:pipeline]}
  }

def increment_depth(depth), do: (depth || 0) + 1
def append_trace(trace, name), do: (trace || []) ++ [name]
```

Fork functions are:

- **Pure** — no side effects, just value transformation
- **Per-key** — each ambient key can have its own fork function
- **Serializable** — MFA tuples survive checkpointing (unlike closures)
- **Composable** — each nesting level applies its own fork functions

## When to Use Composer vs Jido.Exec

| Feature         | `Jido.Exec.Chain`         | Workflow                       | Orchestrator                |
| --------------- | ------------------------- | ------------------------------ | --------------------------- |
| Execution model | Sequential function calls | FSM with state machine         | LLM-driven ReAct loop       |
| Branching       | No                        | Yes (transitions)              | Yes (LLM decides)           |
| Parallelism     | No                        | Yes (FanOutNode)               | Yes (concurrent tool calls) |
| Suspension      | No                        | Yes                            | Yes                         |
| Nesting         | No                        | Yes                            | Yes                         |
| Observability   | No                        | Yes (OTel spans)               | Yes (OTel spans)            |
| Use case        | Simple pipelines          | Deterministic multi-step flows | Adaptive tool composition   |

Use `Jido.Exec.Chain` for simple sequential pipelines. Use Composer when you need branching, parallelism, suspension, or nesting.
