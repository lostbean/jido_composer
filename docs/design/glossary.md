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

### CheckpointAndStop

A [Directive](#directive) emitted when a [Suspension](#suspension) timeout
exceeds the configured `hibernate_after` threshold. The runtime persists the
agent's checkpoint via `Jido.Persist.hibernate/2`, sends a
`"composer.child.hibernated"` [Signal](#signal) to the parent, and stops the
process. Implemented via the `Jido.AgentServer.DirectiveExec` protocol. See
[Persistence — CheckpointAndStop](hitl/persistence.md#checkpointandstop-directive).

### ChildRef

A serializable struct representing a child agent across process boundaries.
Replaces raw PIDs during checkpointing. Carries `agent_module`, `agent_id`,
`tag`, `checkpoint_key`, `status`, and `phase`. Used by the
[persistence layer](hitl/persistence.md#childref-serializable-child-references)
for checkpoint/restore of nested agent trees.

### Context

A map that flows through a chain of [Nodes](#node). Each node receives context
as input and produces updated context as output. Context accumulates results via
[deep merge](#deep-merge). Internally structured as three
[layers](#context-layers): ambient, working, and fork functions.

### Context Layers

The three-layer context model separating read-only propagation (ambient),
mutable accumulation (working), and boundary transformations (fork functions).
Nodes receive a flattened view — the layering is managed by the composition
layer. See [Context Flow — Context Layers](nodes/context-flow.md#context-layers).

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
via per-tool metadata (`requires_approval`) and optional runtime policy
functions in strategy options. See
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

### FanOutBranch

A [Directive](#directive) representing a single branch of a
[FanOutNode](#fanoutnode). The [Workflow Strategy](workflow/strategy.md)
decomposes a FanOutNode into individual FanOutBranch directives, each containing
either a RunInstruction (for ActionNode branches) or a SpawnAgent (for AgentNode
branches). This keeps the strategy pure by deferring execution to the runtime.

### FanOutNode

A [Node](#node) type that executes multiple child nodes concurrently and merges
their results. Encapsulates parallel execution behind the standard Node
interface — the [Machine](#machine) sees a single state while multiple branches
run simultaneously. Branches can be ActionNodes, AgentNodes, or any other Node
type. Supports backpressure via `max_concurrency` and partial completion when
branches [suspend](#suspension). See
[Nodes — FanOutNode](nodes/README.md#fanoutnode).

### Fork Function

An MFA tuple applied at agent boundaries (SpawnAgent) to transform
[ambient context](#context-layers) for the child. Examples include creating
child OTel spans from parent spans, or generating derived correlation IDs. Fork
functions use MFA tuples (not closures) for serializability. See
[Context Flow — Fork Functions](nodes/context-flow.md#fork-functions).

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

### LLM Integration (LLMAction)

Internal action (Jido.Composer.Orchestrator.LLMAction) that calls
[req_llm](https://hexdocs.pm/req_llm) directly for text generation
(`generate_text` / `stream_text`). The [Orchestrator](#orchestrator) emits it
via RunInstruction; there is no facade layer. See
[LLM Integration](orchestrator/llm-integration.md).

### Machine

The pure FSM data structure used by the [Workflow](#workflow) pattern. Holds
current state, transition rules, node bindings, accumulated
[context](#context-layers), and execution history. See
[State Machine](workflow/state-machine.md).

### NodeIO

A typed envelope wrapping node output with type metadata (`:map`, `:text`, or
`:object`). The `to_map/1` function converts any typed output back to a map for
monoidal deep merge, preserving the [composition guarantees](foundations.md).
See [Typed I/O](nodes/typed-io.md).

### Node

The uniform interface all [Workflow](#workflow) and [Orchestrator](#orchestrator)
participants implement. A node is a function from context to context:
`run(node, context, opts) -> {:ok, context} | {:ok, context, outcome} | {:error, reason}`.
See [Nodes](nodes/README.md).

### Obs

A pure data struct that encapsulates [observability](observability.md) span
state for a strategy. `Orchestrator.Obs` holds agent, LLM, tool, and iteration
span contexts plus cumulative token counts. `Workflow.Obs` holds agent and node
span contexts. Strategies store a single `_obs` field containing the
appropriate Obs struct, which is reset to `Obs.new()` during
[checkpoint](hitl/persistence.md) serialization. See
[Observability — Obs Structs](observability.md#obs-structs).

### OtelCtx

A utility module (`Jido.Composer.OtelCtx`) that centralizes OpenTelemetry
process-dictionary context management. Provides `with_parent_context/2` for
guaranteed save/attach/restore via `try/after`, and gracefully no-ops when
OpenTelemetry is not loaded. Used by both DSL runtimes for
[nested agent span propagation](observability.md#nested-agent-span-propagation).

### Orchestrator

A composition pattern where an [LLM](#llm-integration-llmaction) dynamically
selects and invokes available [Nodes](#node) at runtime using a ReAct-style
loop. See [Orchestrator](orchestrator/README.md).

### Outcome

An atom returned by a [Node](#node) alongside its result context. Outcomes drive
[Workflow](#workflow) transitions (e.g., `:ok`, `:error`, `:invalid`). The
default outcome when none is specified is `:ok`.

### Resume

The external API (`Jido.Composer.Resume`) for resuming [suspended](#suspension)
agents. Handles both live agents (deliver signal directly) and checkpointed
agents (thaw from storage, then deliver). Provides idempotency via
[Suspension](#suspension) ID matching and optional compare-and-swap on
[checkpoint](#checkpoint-structure) status. See
[Persistence — Targeted Resume](hitl/persistence.md#targeted-resume).

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

A reserved [outcome](#outcome) (`:suspend`) returned by any node that needs to
pause the flow. Originally used only by [HumanNode](#humannode), now generalized
to support any [suspension reason](#suspension) (rate limits, async completion,
external jobs). The strategy does not look up a transition for `:suspend`;
instead it pauses the flow, emits a Suspend [directive](#directive), and waits
for a resume signal. See
[Strategy Integration](hitl/strategy-integration.md).

### Suspend (Directive)

A generalized [Directive](#directive) emitted when a flow suspends for any
reason. Carries a [Suspension](#suspension) struct, notification configuration,
and hibernate flag. The runtime delivers the notification and optionally
hibernates the agent. See
[Strategy Integration](hitl/strategy-integration.md#suspend-directive).

### SuspendForHuman

A convenience wrapper that builds a [Suspend directive](#suspend-directive) with
`reason: :human_input` and an embedded
[ApprovalRequest](#approvalrequest). Backward compatible with existing HITL
code. See
[Strategy Integration](hitl/strategy-integration.md#suspendforhuman-convenience-wrapper).

### Suspension

A serializable struct representing the metadata of a paused computation.
Generalizes [ApprovalRequest](#approvalrequest) to cover any suspension reason:
`:human_input`, `:rate_limit`, `:async_completion`, `:external_job`, or
`:custom`. Carried by the [Suspend directive](#suspend-directive) and stored in
strategy state as `pending_suspension`. See
[HITL — Generalized Suspension](hitl/README.md#generalized-suspension).

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

A [Machine](#machine) state from which no further execution occurs. When the
machine reaches a terminal state, the [Workflow](#workflow) is complete. If
neither `terminal_states` nor `success_states` is configured, the convention
defaults `:done` and `:failed` apply (with `:done` as the success state). When
custom terminal states are provided, `success_states` must also be specified to
indicate which terminal states represent successful completion. See
[State Machine — Terminal States](workflow/state-machine.md#terminal-states).

### Tool

A structured description of a [Node](#node) formatted for LLM consumption. Tools
have a name, description, and JSON Schema parameters. The AgentTool adapter
converts nodes to tools and maps tool call results back to node execution.

### Cassette

A JSON file that records HTTP request/response pairs for test replay. Created
by [ReqCassette](https://hexdocs.pm/req_cassette) during a recording run and
replayed in subsequent test runs without network access. Cassettes are the
preferred test data source over mocks. See [Testing Strategy](testing.md).

### Replay Directives

Directives generated by `Checkpoint.replay_directives/1` to re-establish
in-flight operations after restoring from a checkpoint. For workflows, this
means re-spawning children that were in the `:spawning` phase. For
orchestrators, this means re-emitting LLM calls or re-dispatching pending tool
calls from conversation history. The [Resume](#resume) module automatically
prepends replay directives when resuming a thawed agent. See
[Persistence — Handling In-Flight Operations](hitl/persistence.md#handling-in-flight-operations).

### Req Options

A keyword list passed through [LLMAction](#llm-integration-llmaction) params
under the `:req_options` key. LLMAction maps this to req_llm's
`:req_http_options`, which passes options through to the underlying Req HTTP
calls. Used to inject the [Cassette](#cassette) plug for testing. See
[Req Options Propagation](testing.md#req-options-propagation).

### Workflow

A composition pattern where a deterministic [FSM](#machine) drives execution
through a sequence of [Nodes](#node). Transitions are fully determined by
[Outcomes](#outcome) — no LLM decisions. See [Workflow](workflow/README.md).
