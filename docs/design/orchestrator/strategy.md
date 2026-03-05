# Orchestrator Strategy

The Orchestrator Strategy implements the `Jido.Agent.Strategy` behaviour to
drive the [ReAct loop](README.md). It manages conversation state, LLM
invocations, tool execution, and result accumulation.

## Strategy State

The strategy stores its state under `agent.state.__strategy__`:

| Field                | Type                        | Purpose                                                               |
| -------------------- | --------------------------- | --------------------------------------------------------------------- |
| `status`             | atom                        | `:idle`, `:awaiting_llm`, `:awaiting_tools`, `:completed`, `:error`   |
| `nodes`              | `%{String.t() => Node.t()}` | Available nodes indexed by name                                       |
| `llm_module`         | module                      | Implements [LLM Behaviour](llm-behaviour.md)                          |
| `system_prompt`      | `String.t()`                | System instructions for the LLM                                       |
| `conversation`       | `term()`                    | Opaque conversation state owned by the [LLM module](llm-behaviour.md) |
| `tools`              | `[tool]`                    | Tool descriptions derived from nodes                                  |
| `pending_tool_calls` | `[tool_call]`               | In-flight tool executions                                             |
| `context`            | map                         | Accumulated [context](../nodes/context-flow.md)                       |
| `iteration`          | integer                     | Current loop iteration                                                |
| `max_iterations`     | integer                     | Safety limit                                                          |
| `req_options`        | keyword                     | Opaque HTTP options forwarded to [LLM generate/3](llm-behaviour.md)   |
| `result`             | any                         | Final answer when complete                                            |

## Status Lifecycle

```mermaid
stateDiagram-v2
    [*] --> idle
    idle --> awaiting_llm : query received
    awaiting_llm --> awaiting_tools : tool_calls returned
    awaiting_llm --> completed : final_answer returned
    awaiting_llm --> error : LLM error or max iterations
    awaiting_tools --> awaiting_llm : all tool results collected
    awaiting_tools --> error : tool execution error
    completed --> [*]
    error --> [*]
```

## Signal Routes

| Signal Type                          | Target                                         | Purpose                |
| ------------------------------------ | ---------------------------------------------- | ---------------------- |
| `composer.orchestrator.query`        | `{:strategy_cmd, :orchestrator_start}`         | Begin orchestration    |
| `composer.orchestrator.child.result` | `{:strategy_cmd, :orchestrator_child_result}`  | Result from AgentNode  |
| `jido.agent.child.started`           | `{:strategy_cmd, :orchestrator_child_started}` | Child agent ready      |
| `jido.agent.child.exit`              | `{:strategy_cmd, :orchestrator_child_exit}`    | Child agent terminated |

## Command Actions

| Action                        | Trigger                             | Behaviour                                        |
| ----------------------------- | ----------------------------------- | ------------------------------------------------ |
| `:orchestrator_start`         | External query signal               | Build initial messages, call LLM                 |
| `:orchestrator_llm_result`    | RunInstruction result (LLM call)    | Process LLM response: dispatch tools or finalize |
| `:orchestrator_tool_result`   | RunInstruction result (action node) | Collect tool result, check if all complete       |
| `:orchestrator_child_result`  | Child agent signal (agent node)     | Same as tool_result for AgentNode                |
| `:orchestrator_child_started` | SpawnAgent confirmation             | Send context to child                            |
| `:orchestrator_child_exit`    | Child process terminated            | Handle unexpected exit                           |

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

The strategy never calls the LLM module directly. Instead, it wraps the LLM
call in an internal action and emits a RunInstruction directive. This action:

1. Calls `llm_module.generate(conversation, tool_results, tools, opts)`
2. Returns the `{response, updated_conversation}` as an instruction result

The result is routed back to `cmd/3` as `:orchestrator_llm_result`. This keeps
the strategy pure and testable. The strategy stores the updated `conversation`
term in its state for the next LLM call. It never inspects the conversation —
the LLM module owns the message format. See
[LLM Behaviour — Conversation State Ownership](llm-behaviour.md#conversation-state-ownership).

The `opts` passed to `generate/4` include any `:req_options` from the
strategy configuration. This enables [cassette-based testing](../testing.md)
by injecting a plug that intercepts HTTP calls. The strategy treats
`req_options` as opaque — it passes them through without inspection. See
[LLM Behaviour — Req Options Propagation](llm-behaviour.md#req-options-propagation).

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
(`%{id, name, result}`) and passed to the next `generate/4` call. The LLM
module converts them to provider-specific message formats internally.

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
