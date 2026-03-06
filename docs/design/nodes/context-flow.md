# Context Flow

Context is the data that flows through a composition. Each
[Node](README.md) receives context as input and produces updated context as
output. Results accumulate via **scoped deep merge** — each node's output is
stored under a key derived from its name, preventing cross-node key collisions.

## Scoped Accumulation Model

```mermaid
flowchart LR
    C0["Initial Context<br/>%{input: data}"]
    N1["Node: extract"]
    C1["%{input: data,<br/>extract: %{records: [...]}}"]
    N2["Node: transform"]
    C2["%{input: data,<br/>extract: %{records: [...]},<br/>transform: %{cleaned: [...]}}"]
    N3["Node: load"]
    C3["%{input: data,<br/>extract: %{...},<br/>transform: %{...},<br/>load: %{count: 42}}"]

    C0 --> N1 --> C1 --> N2 --> C2 --> N3 --> C3
```

Each node receives the **full accumulated context** from all preceding nodes.
The node's result is stored under a scope key (the node's name or the workflow
state name) via deep merge. This prevents data loss when multiple nodes produce
values of the same shape (e.g., lists).

## Output Scoping

When a node named `extract` returns `{:ok, %{records: [...], count: 5}}`, the
composition layer stores it as:

```elixir
%{extract: %{records: [...], count: 5}}
```

This scoped result is deep-merged into the accumulated context. Downstream
nodes read from the scope: `context.extract.records`.

| Aspect               | Behaviour                                                  |
| -------------------- | ---------------------------------------------------------- |
| **Scope key**        | Workflow: the state name atom. Orchestrator: the tool name |
| **Input to node**    | Full accumulated context (all scopes visible)              |
| **Output from node** | Raw result map (node does not add its own scope)           |
| **Scoping**          | Applied by the composition layer, not the node itself      |
| **Re-execution**     | Same node re-running overwrites its own scope              |

### Within-Node Accumulation

Because each node receives the full context — including its own previous output
— a node that runs multiple times (e.g., in a loop or retry) can read its
prior result and append to it:

```elixir
def run(context, _opts) do
  previous = context[:my_node][:items] || []
  new_items = do_work()
  {:ok, %{items: previous ++ new_items}}
end
```

The scoping prevents collisions between nodes; within a single node, the author
controls the merge semantics.

## Deep Merge Semantics

Deep merge recursively merges nested maps. Within a scope, this preserves
nested structure:

| Operation                         | Shallow Merge            | Deep Merge                             |
| --------------------------------- | ------------------------ | -------------------------------------- |
| `%{a: %{x: 1}}` + `%{a: %{y: 2}}` | `%{a: %{y: 2}}` (x lost) | `%{a: %{x: 1, y: 2}}` (both preserved) |
| `%{a: 1}` + `%{b: 2}`             | `%{a: 1, b: 2}`          | `%{a: 1, b: 2}` (same)                 |
| `%{a: 1}` + `%{a: 3}`             | `%{a: 3}`                | `%{a: 3}` (same — scalars overwrite)   |

### Non-Map Values

Deep merge treats non-map values (lists, scalars, tuples) as opaque — the
right-hand side replaces the left. `deep_merge(%{items: [1]}, %{items: [2]})`
yields `%{items: [2]}`, not `[1, 2]`. This is safe under scoped accumulation
because each node owns its scope and controls its own list semantics. Cross-node
list collisions cannot occur.

## Mathematical Foundation

Nodes form an **endomorphism monoid** over context maps, composed via Kleisli
arrows:

| Property          | Guarantee                                                           |
| ----------------- | ------------------------------------------------------------------- |
| **Closure**       | A node always produces a map from a map                             |
| **Associativity** | `(A >> B) >> C` = `A >> (B >> C)` — grouping doesn't affect results |
| **Identity**      | A node that returns its input unchanged is the identity element     |

The Kleisli arrow wrapping (`{:ok, map} | {:error, reason}`) provides
short-circuit error handling: if any node returns `{:error, reason}`, the
composition halts.

Scoping strengthens the monoid guarantee: because each node writes to a
distinct key, the merge operation is equivalent to `Map.put` on disjoint keys,
which is trivially associative and avoids the deep merge edge cases with
non-map values.

For the full categorical treatment see [Foundations](../foundations.md).

## Context in Workflows

In a [Workflow](../workflow/README.md), context flows through the
[Machine](../workflow/state-machine.md). The scope key is the **state name**:

```mermaid
flowchart TB
    subgraph Machine
        S1["State: extract"]
        S2["State: transform"]
        S3["State: load"]
        S4["State: done"]
    end

    C0["Initial Context"] --> S1
    S1 -->|":ok → scope under :extract"| S2
    S2 -->|":ok → scope under :transform"| S3
    S3 -->|":ok → scope under :load"| S4
    S4 --> CF["Final Context<br/>%{extract: %{...}, transform: %{...}, load: %{...}}"]
```

The Machine struct holds the accumulated context and updates it after each node
execution. When the machine reaches a [terminal state](../glossary.md#terminal-state),
the accumulated context (with all scopes) is the workflow's result.

## Context in Orchestrators

In an [Orchestrator](../orchestrator/README.md), context accumulates across
iterations of the ReAct loop. Each tool call result is scoped under the
**tool name** (derived from the node's name). The LLM sees the accumulated
context in the conversation history to inform its next decision.

When the LLM calls the same tool multiple times across iterations, the second
call's result overwrites the first under the same scope key. The tool
implementation can read its previous output from context and append if needed.

## Context Layers

Context carries three distinct layers, each with different propagation semantics:

```mermaid
graph TB
    subgraph "Context"
        A["Ambient<br/>(read-only)"]
        W["Working<br/>(mutable, scoped)"]
        F["Fork Functions<br/>(MFA tuples)"]
    end

    A -->|"flows down unchanged"| Child["Child Agent"]
    W -->|"scoped deep merge"| Child
    F -->|"applied at boundary"| Child
```

| Layer        | Mutability | Scope               | Examples                            |
| ------------ | ---------- | ------------------- | ----------------------------------- |
| **Ambient**  | Read-only  | Propagates downward | `org_id`, `user_id`, `trace_id`     |
| **Working**  | Mutable    | Scoped deep merge   | Node results, accumulated data      |
| **Fork Fns** | Applied    | At agent boundaries | OTel span creation, correlation IDs |

### Ambient

Data that must survive the entire composition tree without modification. Nodes
read ambient data but cannot change it. The composition layer is the sole
gatekeeper — node results never modify ambient context.

Ambient keys are extracted from the initial context during workflow/orchestrator
start. They are declared in the DSL configuration.

### Working

The existing scoped deep merge model described above. Each node's output is
scoped under its name and merged into the working layer. This is where all
node result accumulation happens.

### Fork Functions

Named MFA tuples applied at agent boundaries (when a SpawnAgent directive
creates a child). Fork functions transform the ambient context for the child —
for example, creating a child OTel span from the parent span, or generating a
derived correlation ID.

Fork functions use MFA tuples (not closures) for serializability. They receive
`(ambient, working)` as arguments and return the transformed ambient map.

| Property            | Guarantee                                                                                                                     |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| **Direction**       | Ambient flows downward only — children never modify parent                                                                    |
| **Serializable**    | MFA tuples survive checkpoint/restore                                                                                         |
| **At boundaries**   | Fork runs only at SpawnAgent, not within a single agent                                                                       |
| **FanOut branches** | Branches share ambient without fork (they are products, not functor embeddings). Fork runs only when a branch is an AgentNode |

### How Nodes See Context

Nodes still receive a flat `map()`. The Node behaviour does not change. The
composition layer flattens the layered context before passing it to a node,
placing ambient data under the reserved key `__ambient__`:

```
%{
  __ambient__: %{org_id: "acme", trace_id: "abc"},
  extract: %{records: [...]},
  transform: %{cleaned: [...]}
}
```

Nodes that need ambient data access it via `context.__ambient__.org_id`. A
node's result returning `%{__ambient__: modified}` is scoped under its state
name (`%{my_state: %{__ambient__: modified}}`), leaving the real ambient
untouched.

For the categorical treatment of context layers, see
[Foundations — Environment Propagation](../foundations.md#environment-propagation-as-reader-monad).

## Context Across Agent Boundaries

When an [AgentNode](README.md#agentnode) executes, the context crosses a process
boundary. The composition layer:

1. Runs [fork functions](#fork-functions) to transform ambient for the child
2. Serializes the forked context into a [Signal](../glossary.md#signal) payload
3. Sends the signal to the child agent

The child processes this context through its own strategy, then sends the result
back as a signal to the parent. The parent stores the child's result under the
node's scope key in its **working** context.

Context must be serializable (plain maps, no PIDs or references). Fork functions
use MFA tuples precisely for this reason — closures would not survive
serialization.
