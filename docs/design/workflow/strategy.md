# Workflow Strategy

The Workflow Strategy implements the `Jido.Agent.Strategy` behaviour to drive
a [Machine](state-machine.md) through its states. It keeps `cmd/3` pure by
emitting [directives](../glossary.md#directive) for all side effects.

## Strategy State

The strategy stores its state under `agent.state.__strategy__` with the
following structure:

| Field              | Type                 | Purpose                                      |
| ------------------ | -------------------- | -------------------------------------------- |
| `machine`          | `Machine.t()`        | The FSM being driven                         |
| `module`           | module               | Strategy module reference                    |
| `pending_child`    | `nil \| {tag, node}` | Tracks in-flight AgentNode execution         |
| `child_request_id` | `nil \| String.t()`  | Correlation ID for child agent communication |

## Lifecycle

```mermaid
sequenceDiagram
    participant Client
    participant AgentServer
    participant Strategy
    participant Machine
    participant Runtime

    Client->>AgentServer: signal("composer.workflow.start", context)
    AgentServer->>Strategy: cmd(agent, [%Instruction{action: :workflow_start, params: context}], ctx)
    Strategy->>Machine: current_node()
    Machine-->>Strategy: ActionNode (extract)

    Strategy-->>AgentServer: [RunInstruction(extract_action)]
    AgentServer->>Runtime: execute instruction
    Runtime-->>AgentServer: result
    AgentServer->>Strategy: cmd(agent, [%Instruction{action: :workflow_node_result, params: payload}], ctx)

    Strategy->>Machine: apply_result(result)
    Strategy->>Machine: transition(:ok)
    Machine-->>Strategy: new state: transform
    Strategy->>Machine: current_node()
    Machine-->>Strategy: ActionNode (transform)

    Strategy-->>AgentServer: [RunInstruction(transform_action)]

    Note over Strategy,Runtime: ...continues until terminal state...

    Strategy->>Machine: terminal?()
    Machine-->>Strategy: true
    Strategy-->>AgentServer: [] (no directives — done)
```

## Signal Routes

The Workflow Strategy declares the following signal routes:

| Signal Type                      | Target                                     | Purpose                         |
| -------------------------------- | ------------------------------------------ | ------------------------------- |
| `composer.workflow.start`        | `{:strategy_cmd, :workflow_start}`         | Begin workflow execution        |
| `composer.workflow.child.result` | `{:strategy_cmd, :workflow_child_result}`  | Receive result from child agent |
| `jido.agent.child.started`       | `{:strategy_cmd, :workflow_child_started}` | Child agent is ready            |
| `jido.agent.child.exit`          | `{:strategy_cmd, :workflow_child_exit}`    | Child agent terminated          |

## Command Actions

The strategy dispatches on the instruction's `action` field. When RunInstruction
completes, the runtime routes the result back as a `Jido.Instruction` struct
(not a raw tuple). The execution payload has this structure:

```
%Jido.Instruction{
  action: :workflow_node_result,
  params: %{
    status: :ok | :error,
    result: result_map,        # on success
    reason: exception,         # on error
    effects: [],
    instruction: original_instruction,
    meta: %{}
  }
}
```

The strategy pattern-matches on `instruction.action` to dispatch:

| Action                    | Trigger                  | Behaviour                                                                            |
| ------------------------- | ------------------------ | ------------------------------------------------------------------------------------ |
| `:workflow_start`         | External signal          | Initialize machine context, dispatch first node                                      |
| `:workflow_node_result`   | RunInstruction result    | Scope result under state name, extract outcome, apply transition, dispatch next node |
| `:workflow_child_result`  | Child agent signal       | Same as node_result but for AgentNode results                                        |
| `:workflow_child_started` | SpawnAgent confirmation  | Send context to child as signal                                                      |
| `:workflow_child_exit`    | Child process terminated | Handle unexpected exit or cleanup                                                    |

## Execution Flow: ActionNode

```mermaid
flowchart TB
    A["cmd(:workflow_start)"]
    B["Look up current state's node"]
    C{"Is ActionNode?"}
    D["Create Instruction from action module + context"]
    E["Emit RunInstruction directive"]
    F["Runtime executes action"]
    G["cmd(:workflow_node_result, result)"]
    H["Scope result under state name, deep-merge into machine context"]
    I["Extract outcome from result"]
    J["Machine.transition(outcome)"]
    K{"Terminal state?"}
    L["Done — return accumulated context"]
    M["Dispatch next node (go to B)"]

    A --> B --> C
    C -->|yes| D --> E --> F --> G --> H --> I --> J --> K
    K -->|yes| L
    K -->|no| M --> B
```

## Execution Flow: AgentNode

When the current state's node is an AgentNode (sync mode):

```mermaid
sequenceDiagram
    participant Strategy
    participant AgentServer
    participant Child as Child Agent

    Strategy->>AgentServer: SpawnAgent directive (agent_module, tag)
    AgentServer->>Child: start child agent
    Child-->>AgentServer: child_started signal
    AgentServer->>Strategy: cmd(:workflow_child_started)
    Strategy->>AgentServer: Emit signal to child (context as payload)
    AgentServer->>Child: signal with context
    Child->>Child: run own strategy
    Child->>AgentServer: emit_to_parent(result signal)
    AgentServer->>Strategy: cmd(:workflow_child_result, result)
    Strategy->>Strategy: scope result under state name, transition, continue
```

## Error Handling

Errors from node execution result in outcome `:error`. The transition rules
determine what happens next:

- If a `{current_state, :error}` transition exists, follow it
- If a `{:_, :error}` wildcard exists, follow it (commonly maps to `:failed`)
- If no error transition exists, the machine returns an error and the strategy
  emits an Error directive

Unexpected child agent exits (crashes) are delivered as
`jido.agent.child.exit` signals and handled similarly.
