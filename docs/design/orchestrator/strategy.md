# Orchestrator Strategy

The Orchestrator Strategy implements the `Jido.Agent.Strategy` behaviour to
drive the [ReAct loop](README.md). It manages conversation state, LLM
invocations, tool execution, and result accumulation.

## Strategy State

The strategy stores its state under `agent.state.__strategy__`:

| Field                  | Type                        | Purpose                                                                                                                                   |
| ---------------------- | --------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `status`               | atom                        | `:idle`, `:awaiting_llm`, `:awaiting_tools`, `:awaiting_suspension`, `:awaiting_tools_and_suspension`, `:completed`, `:error`             |
| `phase`                | atom                        | [Phase tracking](../hitl/persistence.md#handling-in-flight-operations) for resume replay (`:idle`, `:awaiting_llm`, `:dispatching_tools`) |
| `nodes`                | `%{String.t() => Node.t()}` | Available nodes indexed by name                                                                                                           |
| `model`                | `String.t()`                | req_llm model spec (e.g. `"anthropic:claude-sonnet-4-20250514"`)                                                                          |
| `system_prompt`        | `String.t()`                | System instructions for the LLM                                                                                                           |
| `temperature`          | `float \| nil`              | Sampling temperature                                                                                                                      |
| `max_tokens`           | `integer \| nil`            | Maximum tokens in response                                                                                                                |
| `stream`               | boolean                     | Whether to use streaming generation (default: `false`)                                                                                    |
| `output_schema`        | `map \| nil`                | JSON Schema for structured output (enables object generation)                                                                             |
| `llm_opts`             | keyword                     | Additional options passed through to req_llm                                                                                              |
| `conversation`         | `ReqLLM.Context.t()`        | Conversation history managed by req_llm                                                                                                   |
| `tools`                | `[ReqLLM.Tool.t()]`         | Tool descriptions as `ReqLLM.Tool` structs derived from nodes                                                                             |
| `pending_tool_calls`   | `[tool_call]`               | In-flight tool executions                                                                                                                 |
| `queued_tool_calls`    | `[tool_call]`               | Tool calls awaiting dispatch (backpressure)                                                                                               |
| `suspended_calls`      | `%{id => suspended_call}`   | Tool calls [suspended](../hitl/strategy-integration.md) for non-HITL reasons (rate limit, async)                                          |
| `max_tool_concurrency` | integer \| `:infinity`      | Maximum simultaneous tool executions (default: `:infinity`)                                                                               |
| `context`              | `Context.t()`               | Accumulated [context](../nodes/context-flow.md#context-layers) with ambient, working, and fork layers                                     |
| `ambient_keys`         | `[atom()]`                  | Keys extracted from start params into the [ambient layer](../nodes/context-flow.md#ambient)                                               |
| `iteration`            | integer                     | Current loop iteration                                                                                                                    |
| `max_iterations`       | integer                     | Safety limit                                                                                                                              |
| `req_options`          | keyword                     | Opaque HTTP options forwarded to [LLMAction](llm-integration.md)                                                                          |
| `approval_policy`      | MFA \| nil                  | Dynamic [approval gate](../hitl/strategy-integration.md#orchestrator-approval-gate) function                                              |
| `pending_suspension`   | `nil \| Suspension.t()`     | Tracks any active [suspension](../hitl/README.md)                                                                                         |
| `children`             | `%{tag => ChildRef.t()}`    | Serializable [child references](../hitl/persistence.md#childref-serializable-child-references) for checkpoint/thaw                        |
| `hibernate_after`      | `pos_integer() \| nil`      | Delay (ms) before [checkpoint](../hitl/persistence.md) on suspension                                                                      |
| `result`               | any                         | Final answer when complete (may be [NodeIO](../nodes/typed-io.md))                                                                        |

## Status Lifecycle

```mermaid
stateDiagram-v2
    [*] --> idle
    idle --> awaiting_llm : query received
    awaiting_llm --> awaiting_tools : tool_calls returned
    awaiting_llm --> completed : final_answer returned
    awaiting_llm --> error : LLM error or max iterations
    awaiting_tools --> awaiting_llm : all tool results collected
    awaiting_tools --> awaiting_suspension : running tools finish, suspended remain
    awaiting_tools --> awaiting_tools_and_suspension : tool suspends while others run
    awaiting_tools --> error : tool execution error
    awaiting_tools_and_suspension --> awaiting_suspension : running tools finish
    awaiting_suspension --> awaiting_llm : all suspensions resumed
    completed --> [*]
    error --> [*]
```

## Signal Routes

| Signal Type                          | Target                                         | Purpose                                                                          |
| ------------------------------------ | ---------------------------------------------- | -------------------------------------------------------------------------------- |
| `composer.orchestrator.query`        | `{:strategy_cmd, :orchestrator_start}`         | Begin orchestration                                                              |
| `composer.orchestrator.child.result` | `{:strategy_cmd, :orchestrator_child_result}`  | Result from AgentNode                                                            |
| `jido.agent.child.started`           | `{:strategy_cmd, :orchestrator_child_started}` | Child agent ready                                                                |
| `jido.agent.child.exit`              | `{:strategy_cmd, :orchestrator_child_exit}`    | Child agent terminated                                                           |
| `composer.suspend.resume`            | `{:strategy_cmd, :suspend_resume}`             | Resume from any suspension                                                       |
| `composer.suspend.timeout`           | `{:strategy_cmd, :suspend_timeout}`            | Suspension timeout fired                                                         |
| `composer.hitl.response`             | `{:strategy_cmd, :hitl_response}`              | Human decision (legacy alias)                                                    |
| `composer.hitl.timeout`              | `{:strategy_cmd, :hitl_timeout}`               | HITL timeout (legacy alias)                                                      |
| `composer.child.hibernated`          | `{:strategy_cmd, :child_hibernated}`           | Child agent [checkpointed](../hitl/persistence.md#cascading-checkpoint-protocol) |

## Command Actions

| Action                        | Trigger                             | Behaviour                                                                                            |
| ----------------------------- | ----------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `:orchestrator_start`         | External query signal               | Build initial messages, call LLM                                                                     |
| `:orchestrator_llm_result`    | RunInstruction result (LLM call)    | Process LLM response: dispatch tools or finalize                                                     |
| `:orchestrator_tool_result`   | RunInstruction result (action node) | Collect tool result, check if all complete                                                           |
| `:orchestrator_child_result`  | Child agent signal (agent node)     | Same as tool_result for AgentNode                                                                    |
| `:orchestrator_child_started` | SpawnAgent confirmation             | Send context to child                                                                                |
| `:orchestrator_child_exit`    | Child process terminated            | Handle unexpected exit                                                                               |
| `:suspend_resume`             | Resume signal for suspended tool    | Resume tool from `suspended_calls` — use provided data or re-dispatch                                |
| `:suspend_timeout`            | Suspension timeout fires            | Convert to error tool result, clear `suspended_calls` entry, check completion                        |
| `:child_hibernated`           | Child agent checkpointed            | Update [ChildRef](../hitl/persistence.md#childref-serializable-child-references) status to `:paused` |

## Execution Flow

```mermaid
sequenceDiagram
    participant Client
    participant AgentServer
    participant Strategy
    participant Runtime

    Client->>AgentServer: signal("composer.orchestrator.query", {query, context})
    AgentServer->>Strategy: cmd(:orchestrator_start)

    loop ReAct Loop
        Strategy->>Strategy: Collect tool_results from previous round
        Strategy-->>AgentServer: RunInstruction(llm_generate_action)
        Note over AgentServer,Runtime: generate(conversation, tool_results, tools, opts)
        AgentServer->>Runtime: execute LLM call
        Runtime-->>AgentServer: {response, updated_conversation}
        AgentServer->>Strategy: cmd(:orchestrator_llm_result)

        alt tool_calls
            loop For each tool call
                alt ActionNode
                    Strategy-->>AgentServer: RunInstruction(action)
                    Runtime-->>AgentServer: result
                    AgentServer->>Strategy: cmd(:orchestrator_tool_result)
                else AgentNode
                    Strategy-->>AgentServer: SpawnAgent
                    Note over AgentServer,Runtime: child lifecycle...
                    AgentServer->>Strategy: cmd(:orchestrator_child_result)
                end
            end
            Strategy->>Strategy: Collect tool_results for next generate call
        else final_answer
            Strategy->>Strategy: Set status = completed, store result
            Strategy-->>AgentServer: [] (done)
        else error
            Strategy->>Strategy: Set status = error
            Strategy-->>AgentServer: [Error directive]
        end
    end
```

## LLM Execution via Directives

The strategy never calls ReqLLM directly. Instead, it builds a
`Jido.Instruction` targeting `LLMAction` and emits a RunInstruction directive.
The instruction params contain all LLM-related state as flat keys:
`conversation`, `tool_results`, `tools`, `model`, `query`, `system_prompt`,
`temperature`, `max_tokens`, `stream`, `output_schema`, `llm_opts`,
and `req_options`.

LLMAction calls the appropriate ReqLLM function based on `stream`/`output_schema` and
returns `{response, updated_conversation}` as an instruction result. The result
is routed back to `cmd/3` as `:orchestrator_llm_result`. This keeps the strategy
pure and testable. The strategy stores the updated `ReqLLM.Context` in its state
for the next LLM call. It never inspects the conversation's internal structure
-- req_llm owns the message format. See
[LLM Integration — Conversation State](llm-integration.md#conversation-state).

The `req_options` from strategy state are included in the instruction params.
LLMAction maps them to req_llm's `req_http_options` key, enabling
[cassette-based testing](../testing.md) by injecting a plug that intercepts
HTTP calls. The strategy treats `req_options` as opaque -- it passes them
through without inspection. See
[LLM Integration — Req Options](llm-integration.md#req-options).

## Tool Execution

When the LLM returns tool calls:

- **ActionNode tools** — The strategy creates an Instruction from the node's
  action module with the tool call arguments as params, then emits a
  RunInstruction directive. The result flows back as `:orchestrator_tool_result`.

- **AgentNode tools** — The strategy emits a SpawnAgent directive. The child
  agent lifecycle follows the same pattern as in
  [Workflow AgentNode execution](../workflow/strategy.md#execution-flow-agentnode).
  Results flow back as `:orchestrator_child_result`.

In both cases, results are collected as normalized `tool_result` structs
(`%{id, name, result}`) and passed to the next LLMAction call via
`emit_llm_call/1`. LLMAction converts them to provider-specific message
formats internally via `ReqLLM.Context.tool_result/3`.

## Iteration Safety

The strategy tracks iterations and halts with an error if `max_iterations` is
reached without a final answer. This prevents runaway loops where the LLM
repeatedly calls tools without converging.

## Context Accumulation

Unlike the Workflow where context flows linearly through the machine, the
Orchestrator accumulates context across all tool executions within the ReAct
loop. Each tool result is **scoped under the tool name** (derived from the
node's name) and deep-merged into the strategy's `context` field. This
prevents data loss when multiple tools produce similarly-shaped results.

When the LLM calls the same tool multiple times, the second call's result
overwrites the first under the same scope key. The tool implementation can
read its previous output from `context[tool_name]` and append if needed.

### Context Layers

The Orchestrator uses the same [context layering](../nodes/context-flow.md#context-layers)
model as the Workflow. The `context` field holds a `Context.t()` struct with
three layers:

- **Ambient** — read-only data (e.g., `org_id`, `trace_id`) extracted from
  start params using the `ambient_keys` list declared in the DSL. Ambient is
  also inherited from a parent composition when the orchestrator runs as a
  child agent (via the `__ambient__` key in the flattened context).
- **Working** — mutable tool results accumulated under scoped keys via
  `Context.apply_result/3`.
- **Fork functions** — MFA tuples applied at SpawnAgent boundaries when the
  orchestrator spawns AgentNode tools as children.

#### Initialization

During `init/2`, the strategy reads `ambient:` and `fork_fns:` from the DSL
options and builds a `Context.new(fork_fns: fork_fns)`. During
`:orchestrator_start`, ambient keys are split from the start params and placed
in the ambient layer. If the start params contain an `__ambient__` key (because
this orchestrator is a child of another composition), those inherited ambient
values are merged in as well.

#### Tool Directive Construction

When building directives for tool calls, the strategy uses the context layers:

- **ActionNode tools** — The strategy merges tool call arguments into the
  working layer, then passes `Context.to_flat_map/1` as the instruction params.
  The action receives the full accumulated context including `__ambient__`.
- **AgentNode tools** — The strategy calls `Context.fork_for_child/1` to run
  fork functions (e.g., OTel span creation), then serializes the forked
  context into the SpawnAgent directive's opts.

#### LLM Visibility

The LLM does not see raw ambient context in conversation messages — it sees the
system prompt (which may incorporate ambient data) and tool results (which come
from the working layer).

## Tool Concurrency

The Orchestrator can dispatch multiple tool calls in parallel when the LLM
returns several in a single turn. A configurable `max_tool_concurrency` limit
controls how many tool calls execute simultaneously. When more tool calls are
returned than the limit allows, excess calls are queued and dispatched as
earlier ones complete.

## Tool Suspension

A tool may suspend for non-HITL reasons (rate limits, async external jobs,
resource throttling). The strategy detects suspension through two paths:

| Detection Path | Condition                                                     | Source                      |
| -------------- | ------------------------------------------------------------- | --------------------------- |
| Direct status  | `params[:status] == :suspend`                                 | Strategy-level tests        |
| Effects-based  | `params[:status] == :ok` and `:suspend` in `params[:effects]` | Runtime DirectiveExec paths |

Both paths route to `handle_tool_suspension`, which:

1. Extracts or builds a `Suspension` struct from the tool result
2. Removes the call from `pending_tool_calls`
3. Stores `%{suspension: suspension, call: call}` in `suspended_calls` keyed
   by `suspension.id`
4. Emits a Suspend directive
5. Calls `Checkpoint.maybe_add_checkpoint_and_stop/2` to append a
   CheckpointAndStop directive when `hibernate_after` is configured

When other tool calls are still in flight, the strategy remains in
`:awaiting_tools_and_suspension`. When all running tools finish and only
suspended calls remain, status transitions to `:awaiting_suspension`.

### Tool Suspend Resume

When `cmd(:suspend_resume, %{suspension_id: id})` arrives:

| Condition                 | Behaviour                                                     |
| ------------------------- | ------------------------------------------------------------- |
| `data` provided in resume | Data is used directly as the tool result (no re-execution)    |
| No `data` in resume       | Tool call is re-dispatched via a new RunInstruction directive |
| Unknown `suspension_id`   | Error directive emitted                                       |

In both success paths, the `suspended_calls` entry for the given ID is cleared.
The strategy then calls `check_all_tools_done` to determine if all tool calls
(pending, gated, and suspended) have resolved. If so, it transitions to
`:awaiting_llm` and emits the next LLM call with all collected tool results.

### Tool Suspend Timeout

When `cmd(:suspend_timeout, %{suspension_id: id})` arrives and the suspension
is still active, the strategy converts it to an error tool result, clears the
entry from `suspended_calls`, and checks tool completion. If the suspension was
already resumed, the timeout is a no-op.

## Init Restoration

The `init/2` callback supports two modes:

| Mode       | Condition                                                      | Behaviour                                                        |
| ---------- | -------------------------------------------------------------- | ---------------------------------------------------------------- |
| Fresh init | No existing strategy state, or status is `:idle`               | Builds full state from DSL options                               |
| Restore    | Strategy state exists with matching module and non-idle status | Preserves checkpoint state; rebuilds runtime-derived fields only |

Runtime-derived fields rebuilt during restore: `nodes`, `tools`, `name_atoms`,
`gated_node_names`, `approval_policy`, `req_options`. All other fields
(conversation, suspended_calls, pending_tool_calls, iteration, context, etc.)
are preserved from the checkpoint.

This enables the thaw-start-resume flow: an AgentServer starts with
checkpointed state, `init/2` detects the restored state and avoids overwriting
it, and the subsequent resume signal picks up where the flow left off.

## Checkpoint Integration

The strategy accepts `hibernate_after` in its DSL options and stores it in
strategy state. Whenever a Suspend directive is emitted (from tool suspension,
approval gate, or HITL), `Checkpoint.maybe_add_checkpoint_and_stop/2` inspects
`hibernate_after` and appends a CheckpointAndStop directive if the suspension
timeout exceeds the threshold. See [Persistence](../hitl/persistence.md) for
the full checkpoint lifecycle.
