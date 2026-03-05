# Composition

Jido Composer's key capability is recursive composition — any
[Node](nodes/README.md) can be another agent running its own strategy. This
enables building arbitrarily complex flows from simple building blocks.

## Nesting Patterns

```mermaid
graph TB
    subgraph "Outer: Orchestrator"
        ORC["Coordinator<br/>(LLM decides)"]
    end

    subgraph "Tool: Workflow"
        WF["ETL Pipeline<br/>(deterministic FSM)"]
        E["extract"]
        T["transform"]
        L["load"]
        WF --- E --- T --- L
    end

    subgraph "Tool: Action"
        RA["ResearchAction"]
    end

    ORC -->|"tool call"| WF
    ORC -->|"tool call"| RA
```

A Workflow agent appears as a single [Tool](glossary.md#tool) to the outer
Orchestrator's LLM. When selected, the Orchestrator spawns it as a child agent.
The Workflow runs its entire FSM pipeline internally, then returns the final
result to the parent.

## Supported Compositions

| Outer        | Inner                            | Mechanism                                           |
| ------------ | -------------------------------- | --------------------------------------------------- |
| Workflow     | ActionNode                       | RunInstruction directive                            |
| Workflow     | AgentNode (any agent)            | SpawnAgent directive                                |
| Workflow     | AgentNode (another Workflow)     | SpawnAgent — inner workflow runs its full FSM       |
| Workflow     | AgentNode (an Orchestrator)      | SpawnAgent — inner orchestrator runs its ReAct loop |
| Orchestrator | ActionNode                       | RunInstruction via tool call                        |
| Orchestrator | AgentNode (any agent)            | SpawnAgent via tool call                            |
| Orchestrator | AgentNode (a Workflow)           | SpawnAgent — workflow appears as a single tool      |
| Orchestrator | AgentNode (another Orchestrator) | SpawnAgent — nested orchestration                   |

## Communication Across Boundaries

```mermaid
sequenceDiagram
    participant Parent as Parent Agent
    participant Server as AgentServer
    participant Child as Child Agent

    Parent->>Server: SpawnAgent directive
    Server->>Child: start_link (with parent_ref)
    Child-->>Server: child_started signal
    Server->>Parent: cmd(:child_started)
    Parent->>Server: Emit signal to child (context payload)
    Server->>Child: deliver signal
    Child->>Child: run own strategy to completion
    Child->>Server: emit_to_parent(result signal)
    Server->>Parent: cmd(:child_result, result)
    Parent->>Parent: deep merge result, continue
```

Key properties of this communication model:

| Property         | Description                                                                                                                  |
| ---------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| **Signal-based** | All inter-agent communication flows through [Signals](glossary.md#signal). No direct function calls across agent boundaries. |
| **Serializable** | Context is a plain map — no PIDs, references, or closures. It can cross process boundaries safely.                           |
| **Hierarchical** | The parent-child relationship is tracked by AgentServer. Children have a `__parent__` reference for `emit_to_parent`.        |
| **Isolated**     | Each child runs its own strategy independently. The parent only sees the final result, not intermediate states.              |

## Depth and Recursion

There is no inherent limit on nesting depth. A workflow can contain an
orchestrator that contains another workflow, and so on. Each level adds a
process boundary (SpawnAgent) with the associated overhead:

```mermaid
graph TB
    L1["Level 1: Coordinator (Orchestrator)"]
    L2A["Level 2: ETL (Workflow)"]
    L2B["Level 2: Analysis (Workflow)"]
    L3["Level 3: DataCleanup (Orchestrator)"]

    L1 --> L2A
    L1 --> L2B
    L2A --> L3
```

Each level is a separate agent process. Context flows down as signal payloads
and results flow back up via `emit_to_parent`.

## HITL Across Composition Boundaries

When a nested agent suspends for [human input](hitl/README.md), the pause
interacts with the composition model:

| Behaviour                  | Description                                                                                                                                                          |
| -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Parent isolation**       | The parent does not know the child is paused — it was already waiting for the child result. The [isolation property](#communication-across-boundaries) is preserved. |
| **Concurrent work**        | An Orchestrator can dispatch non-gated tool calls while a gated tool call awaits approval. Work proceeds in parallel where possible.                                 |
| **Cascading checkpoint**   | If the child hibernates during a long pause, it signals the parent, which may also hibernate. See [Persistence](hitl/persistence.md).                                |
| **Cascading cancellation** | If the human rejects, the rejection is internalized within the child. The parent sees a normal result or error — not a special "rejected" outcome.                   |

For the complete analysis of HITL across nested agent trees, including race
conditions and timeout interactions, see
[Nested Propagation](hitl/nested-propagation.md).

## Composition vs. Jido.Exec.Chain

Jido already provides `Jido.Exec.Chain` for sequential action execution. The
key differences:

| Aspect          | Exec.Chain                | Composer Workflow               | Composer Orchestrator            |
| --------------- | ------------------------- | ------------------------------- | -------------------------------- |
| Execution model | Sequential function calls | FSM-driven, directive-based     | LLM-driven ReAct loop            |
| Branching       | None (linear)             | Outcome-driven transitions      | LLM decisions                    |
| Agent support   | No (actions only)         | Yes (AgentNode)                 | Yes (AgentNode)                  |
| Process model   | Single process            | Multi-process (SpawnAgent)      | Multi-process (SpawnAgent)       |
| Observability   | Telemetry only            | FSM state + history + telemetry | Conversation history + telemetry |
| Error handling  | Short-circuit             | Transition to error states      | LLM-aware retry or fail          |

Use `Exec.Chain` for simple, linear action pipelines. Use Composer when you need
branching, agent composition, or LLM-driven decisions.

For the algebraic laws that guarantee safe composition at any nesting depth, see
[Foundations](foundations.md).

## Composition vs. Jido.Plan

Jido's `Plan` module defines DAGs of Instructions with dependency tracking. The
key differences:

| Aspect        | Plan (DAG)                                | Composer Workflow (FSM)                 |
| ------------- | ----------------------------------------- | --------------------------------------- |
| Graph type    | Directed acyclic graph                    | Finite state machine                    |
| Parallelism   | Concurrent execution of independent steps | Sequential (one state active at a time) |
| Branching     | Static dependency edges                   | Dynamic outcome-driven transitions      |
| Runtime model | Batch execution                           | Reactive, event-driven                  |

Plans are better for parallel batch processing with known dependencies. Workflows
are better for sequential pipelines with conditional branching based on runtime
outcomes.
