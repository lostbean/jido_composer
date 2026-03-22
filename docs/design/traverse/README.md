# Traverse: Applying a Node Across a Collection

Traverse is a [composition constructor](../composition-constructors.md) that
applies the same [Node](../nodes/README.md) to each element of a
runtime-determined collection, in parallel, and collects the results.

## Motivation

The five existing node types handle fixed-structure compositions well. But a
common pattern is missing: "a previous step produced N items — process each
one the same way." The number of items is unknown until the preceding step
runs. This is **not** what [FanOutNode](../nodes/README.md#fanoutnode) does:

| Aspect               | FanOutNode (Parallel)                 | Traverse (Map)                     |
| -------------------- | ------------------------------------- | ---------------------------------- |
| Number of branches   | Fixed at node creation                | Determined at runtime from context |
| Branch logic         | Each branch has its own node          | One node applied to every element  |
| Branch identity      | Named: `:review_a`, `:review_b`       | Indexed: item 0, item 1, item 2... |
| Result shape         | Named map: `%{review_a: ..., ...}`    | Ordered list: `[result₀, result₁]` |
| Conceptual operation | Product (do these N different things) | Map (do this one thing N times)    |

These are distinct operations. Combining them into one node type would braid
two concerns together — "which nodes to run" and "how many times to run them."

## Design

### MapNode

A new node type that implements the traverse constructor:

```
MapNode
├── name          — node identifier
├── over          — context key holding the list to iterate
├── action        — action module to apply to each element
├── max_concurrency — concurrency limit (optional)
└── timeout       — per-element timeout (optional)
```

All fields are **values** — no functions stored in the struct. The node is
fully inspectable and serializable, like every other node type.

### Data Flow

```
                    ┌──────────────────────┐
                    │   Previous Node      │
                    │   produces list at   │
                    │   context key :items │
                    └──────────┬───────────┘
                               │
                    ┌──────────▼───────────┐
                    │      MapNode         │
                    │  over: :items        │
                    │  action: ProcessItem │
                    └──────────┬───────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
     ┌────────▼───────┐ ┌─────▼────────┐ ┌─────▼────────┐
     │ ProcessItem    │ │ ProcessItem  │ │ ProcessItem  │
     │ (item₀)        │ │ (item₁)      │ │ (item₂)      │
     └────────┬───────┘ └─────┬────────┘ └─────┬────────┘
              │                │                │
              └────────────────┼────────────────┘
                               │
                    ┌──────────▼───────────┐
                    │  Results collected   │
                    │  as ordered list     │
                    └──────────────────────┘
```

1. MapNode reads the list from `context[over]`
2. For each element, it runs `action` with the element merged into the context
3. All elements run concurrently (up to `max_concurrency`)
4. Results are collected in order as a list
5. The list is stored under the MapNode's scope key in the context

### Input Preparation

Each element needs to be presented to the action as a context map. MapNode
uses a simple convention:

- If the element is a map, it is merged into the base context
- If the element is not a map, it is wrapped as `%{item: element}`

The base context is the full context at the time MapNode runs (including
results from prior steps). Each element gets its own copy — elements do not
see each other's results.

### Result Collection

Results are collected as an ordered list (preserving the input order). This
differs from FanOutNode's named map because traverse has no branch names —
elements are positional.

The result is stored under the MapNode's scope key:

```
context after MapNode = %{
  # ... prior context ...
  process_items: %{
    results: [result₀, result₁, result₂]
  }
}
```

### Empty Collection

When the list at `context[over]` is empty (or the key is missing), MapNode
returns `{:ok, %{results: []}}` — an empty list. No error, no skip.

## Relationship to Other Constructors

MapNode composes with all other constructors:

| Composition                     | Example                                              |
| ------------------------------- | ---------------------------------------------------- |
| Sequence → Traverse             | Extract items, then process each                     |
| Traverse → Choice               | Process items, then branch on aggregate result       |
| Traverse → Parallel             | Process items, then run fixed reviews on aggregation |
| Parallel with Traverse branches | FanOutNode branch contains a MapNode                 |
| Bind containing Traverse        | Orchestrator invokes a workflow that uses MapNode    |
| Traverse of AgentNodes          | Apply a child agent to each item                     |

MapNode is a Node, so it appears as a single state in the
[Machine](../workflow/state-machine.md). The FSM sees one step; the node
internally handles the fan-out and collection.

## Directive-Based Execution

Like FanOutNode, the [Workflow Strategy](../workflow/strategy.md) decomposes
MapNode into individual directives — one per element. This keeps the strategy
pure and allows elements to be any executable type (actions or agents).

MapNode reuses the existing `FanOutBranch` directive infrastructure. Each
element becomes a FanOutBranch with an auto-generated branch name
(`:item_0`, `:item_1`, etc.). The strategy tracks pending elements and
collects results using the same `FanOut.State` machinery.

The key difference from FanOutNode's directive generation: MapNode reads the
list from context at dispatch time (`to_directive/3`), not at creation time.
The node struct holds the context key (`:over`), not the data.

### Backpressure

When `max_concurrency` is set, MapNode dispatches only that many elements
initially and queues the rest. This reuses FanOut.State's queue-draining
mechanism without modification.

### Error Handling

MapNode uses `:fail_fast` by default — the first element failure stops
remaining elements. A `:collect_partial` option may be added later if needed,
but keeping the default simple avoids premature generalization.

## Observability

MapNode participates in the existing [observability](../observability.md)
system:

- One **node span** for the MapNode itself (as with any node)
- Individual element executions appear as child operations within that span
- The span records element count, concurrency, and completion status

## Scope

### In Scope

- MapNode struct with `name`, `over`, `action`, `max_concurrency`, `timeout`
- `run/3` for sync execution (used by tests, FanOut branches)
- `to_directive/3` for strategy-based execution (reusing FanOutBranch)
- Element-level concurrency control via `max_concurrency`
- Integration with Workflow DSL as a valid node type
- Empty collection handling

### Out of Scope (for now)

- Nested traverse (traverse inside traverse) — works naturally since MapNode
  is a Node, but no special support needed
- Custom result aggregation (reduce) — use a subsequent ActionNode
- Streaming/incremental results — would require a different directive model
- AgentNode elements — deferred until ActionNode elements are proven
- Element-specific context transformation functions — keep input preparation
  simple
