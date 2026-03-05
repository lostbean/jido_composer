# jido_composer — Composable Agent Flows via FSM

## Context

Jido provides powerful primitives for agents (Jido.Agent + Strategy), actions (Jido.Action), signals (Jido.Signal), and execution (Jido.Exec / Jido.Plan). However, there's no clean abstraction for composing agents and actions into higher-order flows. Two patterns are needed:

1. **Workflow** — Deterministic FSM-based pipeline where each state binds to an action or sub-agent. No LLM decisions; transitions are fully determined by outcomes.
2. **Orchestrator** — An agent that uses an LLM (or other decision function) to freely compose available sub-agents and actions at runtime.

Both patterns share a **Node** abstraction (uniform `context → context` interface) and support arbitrary nesting (a node can be another agent running its own Workflow or Orchestrator).

**Mathematical foundation** (implicit, not user-facing): Nodes form an endomorphism monoid over context maps (`map → map`), composed via Kleisli arrows (`{:ok, map} | {:error, reason}`). Deep merge is the monoidal operation. This guarantees associativity, identity, and closure.

`jido_composer` is a **new standalone Elixir package** depending only on core Jido packages (`jido`, `jido_action`, `jido_signal`) — no `jido_ai` dependency. The Orchestrator includes an abstract LLM behaviour that any package can implement.

---

## Dependencies

```elixir
# mix.exs
{:jido, "~> 2.0"},
{:jido_action, "~> 2.0"},
{:jido_signal, "~> 2.0"},
{:zoi, "~> 0.17"},
{:splode, "~> 0.3.0"},
{:jason, "~> 1.4"},
{:nimble_options, "~> 1.1"},
{:telemetry, "~> 1.3"},
```

No `fsmx` — we build FSM transitions directly (as `Jido.Agent.Strategy.FSM` already does with its `Machine` struct).

---

## File Structure

```
jido_composer/
├── mix.exs
├── lib/
│   └── jido/
│       └── composer/
│           ├── composer.ex              # Top-level module, docs
│           ├── node.ex                  # Node behaviour
│           ├── node/
│           │   ├── action_node.ex       # Wraps Jido.Action as Node
│           │   ├── agent_node.ex        # Wraps Jido.Agent as Node
│           │   └── human_node.ex        # Human decision gate Node
│           ├── workflow/
│           │   ├── strategy.ex          # Workflow strategy (implements Jido.Agent.Strategy)
│           │   ├── machine.ex           # FSM state machine struct
│           │   └── dsl.ex              # `use Jido.Composer.Workflow` macro
│           ├── orchestrator/
│           │   ├── strategy.ex          # Orchestrator strategy (implements Jido.Agent.Strategy)
│           │   ├── llm.ex              # Abstract LLM behaviour
│           │   ├── agent_tool.ex        # Wraps Node as tool description for LLM
│           │   └── dsl.ex              # `use Jido.Composer.Orchestrator` macro
│           ├── hitl/
│           │   ├── approval_request.ex  # Serializable pending human decision
│           │   └── approval_response.ex # Human's response struct
│           ├── directive/
│           │   └── suspend_for_human.ex # SuspendForHuman directive
│           └── error.ex                 # Composer-specific error types
├── test/
│   ├── test_helper.exs
│   ├── support/
│   │   └── test_actions.ex             # Test action modules
│   ├── jido/composer/
│   │   ├── node_test.exs
│   │   ├── node/
│   │   │   ├── action_node_test.exs
│   │   │   ├── agent_node_test.exs
│   │   │   └── human_node_test.exs
│   │   ├── workflow/
│   │   │   ├── strategy_test.exs
│   │   │   ├── machine_test.exs
│   │   │   └── dsl_test.exs
│   │   └── orchestrator/
│   │       ├── strategy_test.exs
│   │       ├── agent_tool_test.exs
│   │       └── dsl_test.exs
│   ├── jido/composer/
│   │   └── hitl/
│   │       ├── approval_request_test.exs
│   │       └── workflow_hitl_test.exs
│   └── integration/
│       ├── composition_test.exs        # Nested workflow/orchestrator tests
│       └── hitl_integration_test.exs   # Nested HITL + persistence tests
```

---

## Implementation Plan

### Step 1: Project Scaffold

Create the new `jido_composer` repo with:

- `mix.exs` with deps listed above
- Standard project structure (lib/, test/, config/)
- `Jido.Composer` top-level module with moduledoc

### Step 2: Node Behaviour (`lib/jido/composer/node.ex`)

The uniform interface all workflow participants must satisfy.

```elixir
defmodule Jido.Composer.Node do
  @moduledoc "Uniform context-in/context-out interface for workflow participants."

  @type context :: map()
  @type outcome :: atom()  # :ok, :error, or custom atoms for branching
  @type result :: {:ok, context()} | {:ok, context(), outcome()} | {:error, term()}

  @callback run(context :: context(), opts :: keyword()) :: result()
  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback schema() :: keyword() | nil
end
```

**Design notes:**

- `{:ok, context}` implies outcome `:ok`
- `{:ok, context, :some_outcome}` enables conditional FSM transitions
- `{:error, reason}` implies outcome `:error`
- This mirrors the Action `run/2` signature but with explicit outcome support

### Step 3: ActionNode Adapter (`lib/jido/composer/node/action_node.ex`)

Wraps any `Jido.Action` module as a `Node`. Thin adapter since actions already return `{:ok, map()}`.

```elixir
defmodule Jido.Composer.Node.ActionNode do
  @behaviour Jido.Composer.Node

  defstruct [:action_module, :opts]

  def new(action_module, opts \\ [])

  # Delegates to Jido.Exec.run(action_module, context, %{}, opts)
  # Maps {:ok, result} → {:ok, deep_merge(context, result)}
  # Maps {:ok, result, extras} → {:ok, deep_merge(context, result), classify_outcome(extras)}
  # Maps {:error, reason} → {:error, reason}
  def run(context, opts)
  def name(), do: action_module.name()
  def description(), do: action_module.description()
  def schema(), do: action_module.schema()
end
```

**Key**: Uses `DeepMerge.deep_merge(context, result)` to accumulate context — this is the monoidal operation.

### Step 4: AgentNode Adapter (`lib/jido/composer/node/agent_node.ex`)

Wraps any `Jido.Agent` module as a `Node`. Handles three communication modes.

```elixir
defmodule Jido.Composer.Node.AgentNode do
  @behaviour Jido.Composer.Node

  defstruct [:agent_module, :mode, :opts, :on_state, :signal_type]

  @type mode :: :sync | :async | :streaming

  def new(agent_module, opts \\ [])
  # opts:
  #   mode: :sync (default) | :async | :streaming
  #   signal_type: signal type to send (defaults to agent's convention)
  #   on_state: list of FSM states that trigger upstream events (streaming mode)
  #   timeout: ms (default 30_000)

  # Sync: spawns agent, sends signal with context as payload, awaits result
  # Uses Directive.SpawnAgent + Directive.emit_to_pid pattern
  # Returns {:ok, deep_merge(context, result)}

  # Async: returns {:ok, context, :pending} with handle stored in context
  # Caller must await later

  # Streaming: spawns agent, subscribes to state transitions
  # Emits events to parent when agent reaches specified FSM states
end
```

**For the Workflow strategy** (Step 5), AgentNode in sync mode is the simplest path:

- The workflow strategy emits a `SpawnAgent` directive
- Sends the context as a signal to the child
- The child runs its own strategy, produces a result
- Child sends result back via `emit_to_parent`
- Parent receives via signal routing, applies transition

**For the Orchestrator strategy** (Step 7), all three modes are relevant.

### Step 5: Workflow Machine (`lib/jido/composer/workflow/machine.ex`)

Pure FSM struct with configurable transitions. Similar to `Jido.Agent.Strategy.FSM.Machine` but with node bindings.

```elixir
defmodule Jido.Composer.Workflow.Machine do
  defstruct [
    :status,          # current state name (atom)
    :nodes,           # %{state_name => Node.t()}
    :transitions,     # %{{state_name, outcome} => next_state_name}
    :terminal_states, # MapSet of terminal states (default: [:done, :failed])
    :context,         # accumulated context map flowing through the pipeline
    :history          # list of {state, outcome, timestamp} tuples
  ]

  def new(opts)
  def current_node(machine)  # returns the Node bound to current state
  def transition(machine, outcome)  # applies transition, returns {:ok, machine} | {:error, reason}
  def terminal?(machine)  # true if current state is terminal
  def apply_result(machine, result_context)  # deep merges result into flowing context
end
```

**Transition lookup**: Given current state `:extract` and outcome `:ok`, looks up `{:extract, :ok}` in transitions map. Falls back to `{:_, :ok}` (wildcard state) then `{:extract, :_}` (wildcard outcome) then `{:_, :_}` (global fallback).

**Terminal states**: When the machine reaches a terminal state, no node is executed — the workflow is complete. Default terminal states are `:done` and `:failed`.

### Step 6: Workflow Strategy (`lib/jido/composer/workflow/strategy.ex`)

Implements `Jido.Agent.Strategy` behaviour. This is the core of the deterministic pipeline.

```elixir
defmodule Jido.Composer.Workflow.Strategy do
  use Jido.Agent.Strategy

  # Strategy state stored in agent.state.__strategy__:
  # %{
  #   machine: Machine.t(),
  #   module: __MODULE__,
  #   pending_child: nil | {tag, node},  # if waiting for sub-agent
  #   child_request_id: nil | String.t()
  # }

  # init/2: Build Machine from strategy_opts (nodes, transitions, initial)
  # Store in __strategy__ state

  # cmd/3 dispatches on instruction action:
  #   :workflow_start → Begin workflow from initial state
  #   :workflow_node_result → Handle result from RunInstruction (action node)
  #   :workflow_child_result → Handle result from sub-agent (agent node)
  #   :workflow_child_started → Child agent ready
  #   :workflow_child_exit → Child agent terminated

  # signal_routes/1:
  #   "composer.workflow.start" → {:strategy_cmd, :workflow_start}
  #   "composer.workflow.child.result" → {:strategy_cmd, :workflow_child_result}
  #   "jido.agent.child.started" → {:strategy_cmd, :workflow_child_started}
  #   "jido.agent.child.exit" → {:strategy_cmd, :workflow_child_exit}
end
```

**Execution flow for action nodes:**

1. `cmd(agent, [:workflow_start, %{context: initial_context}])` called
2. Strategy looks up current state's node → it's an ActionNode
3. Strategy creates `Instruction` from the ActionNode's action module + context
4. Emits `RunInstruction` directive with `result_action: :workflow_node_result`
5. Runtime executes, routes result back to `cmd/3` as `:workflow_node_result`
6. Strategy deep-merges result into machine context
7. Extracts outcome, applies transition → new state
8. If new state is terminal → done. If not → dispatch next node (step 2)

**Execution flow for agent nodes:**

1. Current state's node is an AgentNode
2. Strategy emits `SpawnAgent` directive for the agent module
3. On `child_started`, emits signal to child with current context as payload
4. Child runs its own strategy, sends result back via `emit_to_parent`
5. Parent receives as `:workflow_child_result`
6. Deep-merge, transition, continue

### Step 7: Workflow DSL (`lib/jido/composer/workflow/dsl.ex`)

Compile-time macro for defining workflow agents.

```elixir
defmodule MyETLPipeline do
  use Jido.Composer.Workflow,
    name: "etl_pipeline",
    nodes: %{
      extract:   {ExtractAction, []},
      transform: {TransformAction, []},
      validate:  {ValidateAction, []},
      load:      {LoadAction, []},
      notify:    {NotifyAgent, mode: :sync}  # sub-agent!
    },
    transitions: %{
      {:extract, :ok}    => :transform,
      {:transform, :ok}  => :validate,
      {:validate, :ok}   => :load,
      {:validate, :invalid} => :notify,  # conditional branch!
      {:load, :ok}       => :done,
      {:notify, :ok}     => :done,
      {:_, :error}       => :failed      # wildcard: any error → failed
    },
    initial: :extract
end
```

The macro:

1. Validates node/transition definitions at compile time
2. Detects unreachable states and missing transitions (warnings)
3. Wraps each node entry into `ActionNode` or `AgentNode` based on type detection
4. Generates `use Jido.Agent` with `strategy: {Jido.Composer.Workflow.Strategy, [nodes: ..., transitions: ..., initial: ...]}`
5. Generates `run/2` and `run_sync/2` convenience functions

### Step 8: LLM Behaviour (`lib/jido/composer/orchestrator/llm.ex`)

Abstract interface for LLM integration. Any package (jido_ai, custom) can implement this.

```elixir
defmodule Jido.Composer.Orchestrator.LLM do
  @moduledoc "Abstract LLM behaviour for orchestrator decision-making."

  @type tool :: %{
    name: String.t(),
    description: String.t(),
    parameters: map()  # JSON Schema
  }

  @type tool_call :: %{
    id: String.t(),
    name: String.t(),
    arguments: map()
  }

  @type message :: %{role: atom(), content: String.t()}

  @type response ::
    {:final_answer, String.t()}
    | {:tool_calls, [tool_call()]}
    | {:error, term()}

  @callback generate(
    messages :: [message()],
    tools :: [tool()],
    opts :: keyword()
  ) :: {:ok, response()} | {:error, term()}
end
```

### Step 9: AgentTool Adapter (`lib/jido/composer/orchestrator/agent_tool.ex`)

Converts a `Node` into a tool description for the LLM.

```elixir
defmodule Jido.Composer.Orchestrator.AgentTool do
  @moduledoc "Converts Nodes into LLM tool descriptions."

  # Generates tool struct from Node's name/description/schema
  def to_tool(node)

  # Converts tool_call arguments back to node context
  def to_context(tool_call)

  # Wraps node execution result as tool result message
  def to_result_message(tool_call_id, node_name, result)
end
```

### Step 10: Orchestrator Strategy (`lib/jido/composer/orchestrator/strategy.ex`)

Implements `Jido.Agent.Strategy`. This is a ReAct-style loop but built from scratch (no jido_ai dependency) using the abstract LLM behaviour.

```elixir
defmodule Jido.Composer.Orchestrator.Strategy do
  use Jido.Agent.Strategy

  # Strategy state:
  # %{
  #   status: :idle | :awaiting_llm | :awaiting_tools | :completed | :error,
  #   nodes: %{name => Node.t()},
  #   llm_module: module(),  # implements Jido.Composer.Orchestrator.LLM
  #   system_prompt: String.t(),
  #   messages: [message()],  # conversation history
  #   tools: [tool()],        # derived from nodes
  #   pending_tool_calls: [tool_call()],
  #   context: map(),         # accumulated context
  #   iteration: integer(),
  #   max_iterations: integer(),
  #   result: any()
  # }

  # Execution loop:
  # 1. Receive query → build initial messages with system prompt + query
  # 2. Call LLM with messages + tools
  #    - For action nodes: RunInstruction directive
  #    - For agent nodes: SpawnAgent + signal
  # 3. LLM returns {:tool_calls, calls} → execute each tool (node)
  # 4. Collect results → append to messages → loop to step 2
  # 5. LLM returns {:final_answer, answer} → done

  # For LLM calls: emits RunInstruction with an internal LLM action
  # that delegates to the configured llm_module.generate/3

  # signal_routes/1:
  #   "composer.orchestrator.query" → {:strategy_cmd, :orchestrator_start}
  #   "composer.orchestrator.child.result" → {:strategy_cmd, :orchestrator_child_result}
  #   etc.
end
```

**Key difference from jido_ai's ReAct**: The Orchestrator strategy is self-contained. It uses the `LLM` behaviour for generation, `Node` for tool execution, and `AgentTool` for tool description generation. No dependency on ReqLLM, jido_ai actions, or the worker delegation pattern.

### Step 11: Orchestrator DSL (`lib/jido/composer/orchestrator/dsl.ex`)

```elixir
defmodule MyCoordinator do
  use Jido.Composer.Orchestrator,
    name: "coordinator",
    llm: MyApp.ClaudeLLM,  # implements Jido.Composer.Orchestrator.LLM
    nodes: [
      {ResearchAgent, description: "Deep research", mode: :sync},
      {WriterAgent, description: "Write content", mode: :sync},
      StoreAction  # regular action, auto-wrapped as ActionNode
    ],
    system_prompt: "You coordinate research and writing.",
    max_iterations: 15
end
```

### Step 12: Nesting Example

The composition test demonstrating nesting:

```elixir
# Inner workflow: deterministic ETL
defmodule ETLWorkflow do
  use Jido.Composer.Workflow,
    name: "etl",
    nodes: %{extract: {Extract, []}, transform: {Transform, []}, load: {Load, []}},
    transitions: %{{:extract, :ok} => :transform, {:transform, :ok} => :load, {:load, :ok} => :done},
    initial: :extract
end

# Outer orchestrator: LLM picks between research, ETL, or direct answer
defmodule Coordinator do
  use Jido.Composer.Orchestrator,
    name: "coordinator",
    llm: TestLLM,
    nodes: [
      {ETLWorkflow, description: "Run ETL pipeline", mode: :sync},
      ResearchAction
    ],
    system_prompt: "..."
end
```

ETLWorkflow appears as a single tool to the Coordinator's LLM. When selected, it spawns as a sub-agent, runs its deterministic FSM, returns the result.

---

## Implementation Order (TDD)

Each step follows a test-first pattern: write the test, verify it fails,
implement, verify it passes, run `mix precommit`.

Cassettes are preferred over mocks wherever HTTP interactions occur. For the
Orchestrator track, cassettes are recorded early so tests drive development
against real LLM response structures.

### Workflow Track

1. **Project scaffold** — mix.exs, basic module structure, test helpers
2. **Node behaviour** — write test for contract, then implement
3. **ActionNode** — write test for deep merge accumulation, then implement
4. **Workflow.Machine** — write test for transitions/wildcards/terminals, then implement
5. **Workflow.Strategy** — write test for directive emission with stub nodes, then implement
6. **Workflow DSL** — write test for compile-time validation + generated functions, then implement
7. **Workflow integration tests** — linear, branching, error handling workflows

### Orchestrator Track (parallel with Workflow Track from step 5)

8. **LLM behaviour** — define callback contract, write cassette-based test for a reference implementation
9. **AgentTool** — write test for node-to-tool conversion, then implement
10. **Record LLM cassettes** — capture real API responses for tool calling, multi-turn, errors
11. **Orchestrator.Strategy** — write cassette-driven tests for ReAct loop, then implement
12. **Orchestrator DSL** — write test for generated functions, then implement

### Composition Track

13. **AgentNode** — write test for struct/mode validation, then implement
14. **Workflow + AgentNode integration** — write test for sub-agent nodes in workflows
15. **Orchestrator + Workflow nesting** — write cassette-driven test for workflow-as-tool
16. **End-to-end tests** — full orchestration flows with recorded LLM cassettes

### HITL Track (after Composition Track)

17. **ApprovalRequest/Response structs** — define serializable structs, write validation tests
18. **HumanNode** — write test for `{:ok, context, :suspend}` contract, prompt evaluation, context filtering
19. **SuspendForHuman directive** — define directive struct, write test for strategy emission
20. **Workflow + HumanNode** — write test for suspend/resume cycle: node returns `:suspend`, strategy pauses, resume signal triggers transition
21. **Workflow HITL timeout** — write test for Schedule-based timeout, timeout outcome transition
22. **Orchestrator approval gate** — write test for tool call partitioning (gated vs ungated), `requires_approval` metadata
23. **Orchestrator concurrent HITL** — write test for mixed tool call states (`awaiting_tools_and_approval`), result collection, rejection with synthetic tool result
24. **Orchestrator rejection policy** — write test for `:continue_siblings`, `:cancel_siblings`, `:abort_iteration`
25. **HITL persistence** — write test for ChildRef serialization, checkpoint/thaw with pending HITL request, idempotent resume
26. **Nested HITL integration** — write test for OuterWorkflow → InnerOrchestrator with HITL gate, cascading checkpoint, top-down resume
27. **HITL DSL options** — write test for `hitl: [...]` configuration in Workflow and Orchestrator DSL macros

---

## Verification

1. **Unit tests**: Each module has dedicated tests (cassette-driven where HTTP is involved)
   - Machine: transition validation, wildcard fallbacks, terminal detection
   - ActionNode: context accumulation via deep merge
   - AgentNode: struct construction, mode validation
   - Workflow Strategy: FSM execution with stub nodes, directive emission
   - LLM implementations: response parsing against real cassettes
   - Orchestrator Strategy: ReAct loop with cassette-driven LLM responses

2. **Integration tests** (cassette-driven for Orchestrator scenarios):
   - Linear workflow (A → B → C → done)
   - Branching workflow (A → B | C based on outcome)
   - Error handling workflow (any error → failed state)
   - Nested workflow (workflow node inside workflow)
   - Orchestrator single tool call (cassette)
   - Orchestrator multi-turn conversation (cassette)
   - Orchestrator calling a workflow as a tool (cassette)
   - Streaming agent node bubbling events
   - Workflow with HumanNode: suspend, resume with approval, resume with rejection
   - Workflow HITL timeout fires → timeout outcome transition
   - Orchestrator approval gate: gated tool call suspend/resume
   - Orchestrator mixed tool calls: concurrent gated + ungated
   - Nested HITL: Workflow → Orchestrator with HITL gate → cascading checkpoint/resume

3. **End-to-end tests** (all cassette-driven):
   - Full orchestration flows against recorded LLM responses
   - Nested compositions with cross-boundary LLM calls
   - Error response handling (rate limits, malformed requests)

4. **Compile-time validation**:
   - DSL warns on unreachable states
   - DSL errors on missing node definitions
   - DSL errors on transitions referencing undefined states

5. **Run tests**: `mix test`
6. **Type checking**: `mix dialyzer`
7. **Code quality**: `mix credo --min-priority high`

---

## Key Reuse from Jido Ecosystem

| What                          | From                        | How Used                                       |
| ----------------------------- | --------------------------- | ---------------------------------------------- |
| Agent struct + lifecycle      | `Jido.Agent`                | Base for Workflow/Orchestrator agents          |
| Strategy behaviour            | `Jido.Agent.Strategy`       | Both strategies implement this                 |
| Directive system              | `Jido.Agent.Directive`      | SpawnAgent, RunInstruction, Emit, etc.         |
| Strategy state helpers        | `Jido.Agent.Strategy.State` | Store FSM/orchestrator state in `__strategy__` |
| Action execution              | `Jido.Exec.run/4`           | Execute action nodes                           |
| Instruction normalization     | `Jido.Instruction`          | Wrap actions for RunInstruction                |
| Signal creation/routing       | `Jido.Signal`               | Inter-agent communication                      |
| Schema validation             | `Zoi`                       | Node schemas, config validation                |
| Error types                   | `Splode`                    | Structured errors                              |
| Deep merge                    | `DeepMerge`                 | Context accumulation (monoidal operation)      |
| Plan DAG (reference)          | `Jido.Plan`                 | Architectural reference for graph validation   |
| Chain composition (reference) | `Jido.Exec.Chain`           | Pattern reference for sequential deep-merge    |
