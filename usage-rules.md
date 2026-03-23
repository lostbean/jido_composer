# Jido Composer Usage Rules

## Intent

Build composable agent topologies via two nestable patterns: deterministic
Workflow (FSM) and dynamic Orchestrator (LLM tool-use loop). Human-in-the-Loop
(HumanNode gates, tool approval, generalized suspension) and durable persistence
(checkpoint/thaw/resume across process boundaries) are first-class concerns. The
uniform Node interface (`context → context`) guarantees any node type composes
with any other at any depth.

## Core Contracts

- All nodes implement `context → context` (endomorphism monoid over maps,
  composed via Kleisli arrows).
- Node types: **ActionNode** (wraps `Jido.Action`), **AgentNode** (wraps
  `Jido.Agent`), **FanOutNode** (parallel branches), **MapNode** (traverse —
  same node over a runtime list), **HumanNode** (suspend for human input),
  **DynamicAgentNode** (assembles sub-agents from skills at runtime).
- Nodes return `{:ok, context}`, `{:ok, context, outcome_atom}`, or
  `{:error, reason}`. HumanNode returns `{:ok, context, :suspend}`.
- Context layers: each node's output merges under its key via deep merge. Access
  upstream results with `get_in(params, [:node_key, :field])`.
- Directives describe side effects: `Suspend`, `SuspendForHuman`,
  `FanOutBranch`, `CheckpointAndStop`.

## HITL & Persistence

- Suspension reasons: `:human_input_required`, `:approval_required`, or custom
  atoms.
- `ApprovalRequest`: serializable struct with unique `id`, `tool_call`,
  `context_snapshot`. `ApprovalResponse`: `approved | rejected | modified` with
  optional `modifications`.
- Checkpoint: `Checkpoint.save/2` serializes state. `ChildRef` replaces live
  PIDs for safe serialization.
- Resume: `Resume.resume/2` thaws from checkpoint. Top-down: parent resumes,
  then re-attaches children.
- Parent isolation: parent doesn't know child is paused. Rejection is
  internalized within child.

## Workflow Patterns

- DSL: `use Jido.Composer.Workflow` with `name`, `nodes` (map of atom → module),
  `transitions` (map of `{state, outcome} => next_state`).
- Transitions are exhaustive; use `{:_, :error} => :failed` as catch-all.
- Custom outcomes: nodes return `{:ok, ctx, :custom_outcome}` to branch.
  Transition map must cover all possible outcomes.
- FanOutNode: `fork_fns` returns list of `{branch_key, fun}` pairs. Results
  merge under each branch key.
- MapNode: applies the same node to each element of a list from context.
  `MapNode.new(name: :process, over: [:generate, :items], node: MyAction)`.
  The `node` field accepts any Node struct (ActionNode, AgentNode, FanOutNode,
  HumanNode, etc.) or a bare action module (auto-wrapped in ActionNode).
  `over` can be an atom (top-level key) or a list of atoms (nested path).
  Results are collected as `%{results: [r0, r1, ...]}`. Uses FanOutBranch
  directives and FanOut.State internally. Empty lists produce `%{results: []}`.
  - Input preparation: map elements are merged into node params; non-map
    elements are wrapped as `%{item: element}`.
  - Missing context key or non-list value → treated as empty list.
  - Use MapNode when the collection size is unknown at definition time and every
    element gets the same processing. Use FanOutNode when branches are
    heterogeneous and fixed at definition time.
  - When using AgentNode as MapNode's child, the agent must be `:sync` mode
    (the default). Async/streaming modes are not directly runnable via `run/3`
    and will error.
- HumanNode: always returns `:suspend` outcome. Pair with `SuspendForHuman`
  directive for approval gates.
- Terminal states: `:done` and `:failed` are convention defaults (with `:done`
  as success state). Custom `terminal_states` require pairing with
  `success_states`; providing one without the other is a compile error.

## Composition Constructors

Five constructors plus one escape hatch cover the full range of workflow shapes:

| Constructor | What It Does                       | Graph Defined At | DSL Expression                  |
| ----------- | ---------------------------------- | ---------------- | ------------------------------- |
| Sequence    | Do A, then B                       | Compile time     | `transitions` map               |
| Parallel    | Do A and B simultaneously          | Compile time     | `FanOutNode` with `branches:`   |
| Choice      | Do A or B based on outcome         | Compile time     | Custom outcomes + transitions   |
| Traverse    | Apply A to each item in a list     | Compile time     | `MapNode` with `over:`, `node:` |
| Identity    | Pass through unchanged             | Compile time     | No-op action                    |
| Bind        | Compute which workflow to run next | Runtime          | Orchestrator DSL                |

- Constructors 1–5 → Workflow. Static graph defined at `defmodule` time. Data
  flows through at runtime (outcomes drive choice, collection sizes drive
  traverse), but graph structure is fixed.
- Bind → Orchestrator. Execution path discovered at runtime by LLM.
- Mix both: Workflow with Orchestrator as a node, or Orchestrator invoking
  Workflows as tools.

## Orchestrator Patterns

- DSL: `use Jido.Composer.Orchestrator` with `name`, `description`, `tools`
  (list of action/agent modules).
- `query_sync/2` drives a ReAct loop: LLM picks tools → execute → feed results
  back → repeat until termination.
- `termination_tool`: a `Jido.Action` module whose schema defines structured
  output. LLM calls it as a regular tool to emit the final answer.
- Tool wrapping: modules listed in `tools` are auto-converted to LLM tool
  descriptions via `AgentTool`.
- Approval gates: per-tool `requires_approval: true` + `approval_policy`
  function. Gated tool calls emit `SuspendForHuman`.
- Streaming: `stream: true` uses Finch directly, bypassing Req plugs. Disable
  streaming when using cassette/stub plugs for testing.
- LLM config: DSL supports `temperature`, `max_tokens`, `stream`,
  `termination_tool`, `llm_opts`.
- **Runtime configuration**: `configure/2` overrides strategy state after
  `new/0` but before `query_sync/3`. Accepts `:system_prompt`, `:nodes`,
  `:model`, `:temperature`, `:max_tokens`, `:req_options`, `:conversation`. The
  `:nodes` override rebuilds tools/name_atoms/schema_keys internally and handles
  termination tool dedup.
- **Read accessors**: `get_action_modules/1` returns current node modules;
  `get_termination_module/1` returns the termination tool module. Use for
  read-filter-write patterns (RBAC).

## Skills & Dynamic Assembly

- **Skill**: pure-data struct (`name`, `description`, `prompt_fragment`,
  `tools`). Packages reusable capabilities without defining modules.
- `Skill.assemble/2`: takes a list of skills + options (`:base_prompt`,
  `:model`, `:max_iterations`, `:temperature`, `:max_tokens`, `:req_options`),
  composes prompt fragments, deduplicates tools, returns a configured
  `BaseOrchestrator` agent ready for `query_sync`.
- **DynamicAgentNode**: Node that wraps `Skill.assemble/2` + `query_sync/3`.
  Parent LLM selects skills by name via `skills: ["math", "data"]` and provides
  a `task` string. The node looks up skills from its registry, assembles a
  sub-agent, runs it, and returns the result.
- Inject DynamicAgentNode via `configure(agent, nodes: [dynamic_node])` — the
  `build_nodes/1` catch-all handles custom node structs via
  `Node.dispatch_name/1`.
- Use direct `Skill.assemble/2` when you want ad-hoc agents without a parent.
  Use DynamicAgentNode when the parent LLM should decide which skills to combine
  per query.

## Composition

- Any node can be another Workflow or Orchestrator (arbitrary nesting).
- AgentNode wraps a `Jido.Agent` as a node — the child runs its own strategy
  internally.
- **Jido.AI agents** (`use Jido.AI.Agent`) are auto-detected via `ask_sync/3`
  and work as first-class nodes. Composer spawns a temporary AgentServer,
  queries it, and shuts it down. Requires the Jido supervision tree to be
  running.
- When used as orchestrator tools, Jido.AI agents expose `{"query": "string"}`
  schema (not internal state fields).
- Context flows top-down; child results merge into parent context under the node
  key.
- FanOutNode `fork_fns` receive the current context and return branch-specific
  params.
- Control spectrum: Workflow only (fully deterministic) → Workflow + HumanNode →
  Workflow containing Orchestrator → Orchestrator containing Workflow →
  Orchestrator only (fully adaptive).

## Testing

- **ReqCassette** for e2e tests with recorded API responses. Never hand-craft
  cassettes; delete and re-record with `RECORD_CASSETTES=true mix test`.
- **LLMStub direct mode** (`LLMStub.setup/1` + `LLMStub.execute/1`):
  process-dictionary queue for strategy tests.
- **LLMStub plug mode** (`LLMStub.setup_req_stub/2`): Req.Test.stub-backed queue
  for DSL `query_sync` tests.
- LLMAction retries once by default — error stubs need 2+ responses to cover the
  retry.
- Disable streaming (`stream: false`) when cassette/stub plug is active (Finch
  bypasses Req plugs).
- Propagate `req_options` for plug injection: LLMAction passes them as
  `req_http_options` to ReqLLM.

## Observability

- `config :jido, :observability, tracer: AgentObs.JidoTracer` enables
  OpenTelemetry tracing.
- AgentObs bridges Jido.Observe spans to OTel via `AgentObs.Handlers.Phoenix`.
- Span hierarchy: AGENT > CHAIN (iteration) > LLM + TOOL. Nested agents parent
  under the outer TOOL span.

## Avoid

- Calling LLM APIs directly; use `Orchestrator` + `LLMAction` which handles tool
  conversion and retries.
- Embedding runtime side effects in node logic; emit directives instead.
- Using `String.to_atom/1` on untrusted input (node keys, outcomes).
- Assuming streaming works with test plugs; always set `stream: false` in
  stub/cassette tests.
- Skipping `mix precommit` before commits.

## References

- `README.md`
- `guides/`
- https://hexdocs.pm/jido_composer
- https://hexdocs.pm/usage_rules/readme.html#usage-rules
