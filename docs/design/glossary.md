# Glossary

Single source of truth for domain terms used throughout the Jido Composer design
documentation.

---

### Action

A discrete, composable unit of functionality in the Jido ecosystem. Actions
implement a `run(params, context)` callback that returns
`{:ok, result_map}` or `{:error, reason}`. Defined via `use Jido.Action`.

### Agent

An immutable data structure that holds state and processes commands via a
[Strategy](#strategy). Agents are purely functional — OTP integration is handled
separately by AgentServer. Defined via `use Jido.Agent`.

### AgentServer

The OTP GenServer runtime that hosts an [Agent](#agent), processes
[Signals](#signal), executes [Directives](#directive), and manages child
processes. Jido Composer strategies run within AgentServer.

### Context

A map that flows through a chain of [Nodes](#node). Each node receives context
as input and produces updated context as output. Context accumulates results via
[deep merge](#deep-merge).

### Directive

A pure description of an external effect for the runtime to execute. Agents and
strategies emit directives but never interpret them. Core directives include
Emit, RunInstruction, SpawnAgent, Schedule, and Stop. See
[Overview — Directive System](overview.md#directive-system).

### Deep Merge

The monoidal operation for [context](#context) accumulation. Nested maps are
merged recursively rather than overwritten. Provided by the `DeepMerge` library.
See [Context Flow](nodes/context-flow.md#deep-merge-semantics) for semantics and
[Foundations](foundations.md) for the algebraic properties.

### DSL

Compile-time macro layer (`use Jido.Composer.Workflow` or
`use Jido.Composer.Orchestrator`) that validates configuration and generates a
Jido Agent wired to the appropriate [Strategy](#strategy).

### Approval Gate

An enforcement mechanism in the [Orchestrator](#orchestrator) that intercepts
[tool calls](#tool) requiring human approval **before** execution. Configured
via per-tool metadata or a dynamic policy function. See
[Strategy Integration — Orchestrator Approval Gate](hitl/strategy-integration.md#orchestrator-approval-gate).

### ApprovalRequest

A serializable struct representing a pending human decision. Constructed by a
[HumanNode](#humannode) and enriched by the strategy with flow identification.
Contains the prompt, allowed responses, visible context, and timeout
configuration. See
[Approval Lifecycle](hitl/approval-lifecycle.md#approvalrequest).

### ApprovalResponse

The human's response to an [ApprovalRequest](#approvalrequest). Carries the
decision atom, optional structured data, respondent identity, and timestamp.
Delivered to the suspended flow as a [Signal](#signal). See
[Approval Lifecycle](hitl/approval-lifecycle.md#approvalresponse).

### FanOutNode

A [Node](#node) type that executes multiple child nodes concurrently and merges
their results. Encapsulates parallel execution behind the standard Node
interface — the [Machine](#machine) sees a single state while multiple branches
run simultaneously. This addresses the limitation that the Machine's single
`status` field cannot represent two active states. See
[Nodes — FanOutNode](nodes/README.md#fanoutnode).

### Error

A structured error type defined via the Splode library in
`Jido.Composer.Error`. Errors are classified into classes (Validation,
Transition, Execution, Communication, Orchestration) to support pattern matching
and consistent formatting. See
[Overview — Error Handling](overview.md#error-handling).

### HumanNode

A [Node](#node) type whose computation is performed by a human. Returns
`{:ok, context, :suspend}` with an [ApprovalRequest](#approvalrequest) in
context. The strategy pauses the flow and waits for an
[ApprovalResponse](#approvalresponse). See
[HumanNode](hitl/human-node.md).

### Instruction

A work order that wraps an [Action](#action) with parameters, context, and
runtime options. Instructions are the unit of execution passed to
RunInstruction directives. Defined in `Jido.Instruction`.

### LLM Facade

A concrete module (`Jido.Composer.Orchestrator.LLM`) that wraps
[req_llm](https://hexdocs.pm/req_llm) for provider-agnostic LLM calls. Exposes
`generate/4` for the [Orchestrator](#orchestrator) strategy. Users can supply
custom modules with the same signature — no `@behaviour` enforcement. See
[LLM Integration](orchestrator/llm-behaviour.md).

### Machine

The pure FSM data structure used by the [Workflow](#workflow) pattern. Holds
current state, transition rules, node bindings, accumulated context, and
execution history. See [State Machine](workflow/state-machine.md).

### Node

The uniform interface all [Workflow](#workflow) and [Orchestrator](#orchestrator)
participants implement. A node is a function from context to context:
`run(context, opts) -> {:ok, context} | {:ok, context, outcome} | {:error, reason}`.
See [Nodes](nodes/README.md).

### Orchestrator

A composition pattern where an [LLM](#llm-facade) dynamically selects and
invokes available [Nodes](#node) at runtime using a ReAct-style loop. See
[Orchestrator](orchestrator/README.md).

### Outcome

An atom returned by a [Node](#node) alongside its result context. Outcomes drive
[Workflow](#workflow) transitions (e.g., `:ok`, `:error`, `:invalid`). The
default outcome when none is specified is `:ok`.

### Signal

The universal message format in Jido, implementing the CloudEvents v1.0.2
specification. Signals carry typed, structured payloads and are routed to
strategies via signal routes. Defined in `Jido.Signal`.

### Signal Route

A mapping from a signal type string to a strategy command target. Strategies
declare signal routes so the AgentServer knows how to route incoming signals
to the appropriate `cmd/3` invocation. Routes are **mandatory** — AgentServer
has no default fallback for unknown signal types and produces a `RoutingError`
for unrouted signals. The only built-in route is `jido.agent.stop`. See
[Overview — Signal Integration](overview.md#signal-integration).

### Suspend

A reserved [outcome](#outcome) (`:suspend`) returned by a
[HumanNode](#humannode). The strategy does not look up a transition for
`:suspend`; instead it pauses the flow, emits a SuspendForHuman
[directive](#directive), and waits for a resume signal. See
[Strategy Integration](hitl/strategy-integration.md).

### SuspendForHuman

A [Directive](#directive) emitted when a flow suspends for human input. Carries
the [ApprovalRequest](#approvalrequest), notification configuration, and
hibernate flag. The runtime delivers the request to the configured notification
channel. See
[Strategy Integration](hitl/strategy-integration.md#suspendforhuman-directive).

### Snapshot

A stable, cross-strategy view of execution state. Strategies expose their
internal state through a `Strategy.Snapshot` struct with fields for status,
completion, result, and details — without exposing internal structure.

### Strategy

A behaviour that controls how an [Agent](#agent) processes commands. Strategies
implement `cmd/3` (required), plus optional `init/2`, `tick/2`, `snapshot/2`,
`action_spec/1`, and `signal_routes/1` callbacks. Both Workflow and Orchestrator
are implemented as strategies. See [Overview — Strategy System](overview.md#strategy-system).

### Strategy State

Strategy-specific data stored under the reserved key `__strategy__` in
`agent.state`. Managed via `Jido.Agent.Strategy.State` helpers (get, put,
update, status, terminal?).

### Terminal State

A [Machine](#machine) state from which no further execution occurs. Default
terminal states are `:done` and `:failed`. When the machine reaches a terminal
state, the [Workflow](#workflow) is complete.

### Tool

A structured description of a [Node](#node) formatted for LLM consumption. Tools
have a name, description, and JSON Schema parameters. The AgentTool adapter
converts nodes to tools and maps tool call results back to node execution.

### Cassette

A JSON file that records HTTP request/response pairs for test replay. Created
by [ReqCassette](https://hexdocs.pm/req_cassette) during a recording run and
replayed in subsequent test runs without network access. Cassettes are the
preferred test data source over mocks. See [Testing Strategy](testing.md).

### Req Options

A keyword list passed through the [LLM Facade](#llm-facade) `opts`
under the `:req_options` key. The facade maps this to req_llm's
`:req_http_options`, which passes options through to the underlying Req HTTP
calls. Used to inject the [Cassette](#cassette) plug for testing. See
[Req Options Propagation](testing.md#req-options-propagation).

### Workflow

A composition pattern where a deterministic [FSM](#machine) drives execution
through a sequence of [Nodes](#node). Transitions are fully determined by
[Outcomes](#outcome) — no LLM decisions. See [Workflow](workflow/README.md).
