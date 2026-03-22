# Traverse Implementation Plan

Step-by-step plan for implementing the traverse constructor (MapNode),
following the project's TDD approach and Simple Made Easy principles.

## Principles Guiding This Plan

1. **MapNode is a separate thing from FanOutNode.** They are distinct
   constructors solving different problems. No modification to FanOutNode.
2. **The node struct is a value.** No functions stored in fields. All fields
   are inspectable, serializable data.
3. **Reuse existing infrastructure.** MapNode reuses `FanOutBranch` directives
   and `FanOut.State` for tracking — no new directive types needed.
4. **Start narrow, widen later.** Begin with ActionNode elements only. Add
   AgentNode elements as a follow-up if needed.

## Phase 1: MapNode Struct and Sync Execution

**Goal**: A working MapNode that can be used in `run/3` (sync path).

### Step 1.1: Write MapNode unit tests

Create `test/jido/composer/node/map_node_test.exs`.

Tests to write:

- `new/1` with valid opts returns `{:ok, %MapNode{}}`
- `new/1` without required fields returns error
- `name/1` returns the name
- `description/1` includes the action and over key
- `run/3` with a list of items runs the action on each
- `run/3` with empty list returns `{:ok, %{results: []}}`
- `run/3` with missing context key returns `{:ok, %{results: []}}`
- `run/3` preserves input order
- `run/3` with map elements merges element into context
- `run/3` with non-map elements wraps as `%{item: element}`
- `run/3` with `max_concurrency` limits parallel execution
- `run/3` with a failing element returns error (fail-fast)

Use the existing test helpers and action modules from `test/support/`.

### Step 1.2: Implement MapNode struct

Create `lib/jido/composer/node/map_node.ex`.

```elixir
defmodule Jido.Composer.Node.MapNode do
  @behaviour Jido.Composer.Node

  @default_timeout 30_000

  @enforce_keys [:name, :over, :action]
  defstruct [:name, :over, :action, :max_concurrency, timeout: @default_timeout]
end
```

Fields:

- `name` — `String.t()`, node identifier
- `over` — `atom()`, context key holding the list
- `action` — `module()`, a `Jido.Action` module
- `max_concurrency` — `pos_integer() | nil`
- `timeout` — `pos_integer() | :infinity`

Implement:

- `new/1` — validate required fields and that action is a valid Action module
- `run/3` — read list from context, `Task.async_stream` over elements, collect
  ordered results
- `name/1`, `description/1` — metadata callbacks

### Step 1.3: Verify tests pass

Run `mix test test/jido/composer/node/map_node_test.exs`.

## Phase 2: Directive-Based Execution (Workflow Integration)

**Goal**: MapNode works inside a Workflow via the strategy's directive system.

### Step 2.1: Write directive generation tests

Add tests to `map_node_test.exs`:

- `to_directive/3` with a list in context generates one `FanOutBranch` per
  element
- `to_directive/3` returns `fan_out` side effect with `FanOut.State`
- `to_directive/3` with empty list generates zero directives and returns
  immediate completion
- `to_directive/3` respects `max_concurrency` (dispatches limited batch,
  queues rest)

### Step 2.2: Implement `to_directive/3`

This is the key integration point. MapNode reads the list from context and
generates FanOutBranch directives:

1. Extract list from `flat_context[over]`
2. For each element, build an `ActionNode` directive with element-enriched
   context
3. Assign auto-generated branch names (`:item_0`, `:item_1`, ...)
4. Split into dispatch batch and queue based on `max_concurrency`
5. Create `FanOut.State` from dispatched names and queue
6. Return `{:ok, directives, fan_out: fan_out_state}`

The generated directives are standard `FanOutBranch` structs — the strategy
already knows how to execute these and track results via `FanOut.State`.

### Step 2.3: Handle MapNode in strategy dispatch

The Workflow Strategy's `build_node_dispatch_opts/2` function needs a clause
for MapNode to provide the `fan_out_id`, same as FanOutNode:

```elixir
%MapNode{} ->
  Keyword.put(base, :fan_out_id, generate_fan_out_id())
```

This is a one-line addition. The rest of the FanOut result-handling code
(`handle_fan_out_branch_result`, `drain_queue`, `completion_status`,
`merge_results`) works unchanged because MapNode produces the same directive
types and side effects.

### Step 2.4: Custom result merging for MapNode

FanOutNode's default merge scopes results under branch names:
`%{review_a: ..., review_b: ...}`. MapNode needs a list:
`%{results: [result₀, result₁, ...]}`.

Two options:

- **Option A**: MapNode passes a custom merge function to `FanOut.State` that
  collects results into an ordered list. FanOut.State already supports custom
  merge via the `merge` field.
- **Option B**: MapNode uses a merge function that sorts by branch name
  (`:item_0`, `:item_1`) and strips names.

Option A is simpler. The merge function is: sort completed_results by branch
index, extract values into a list, wrap in `%{results: list}`.

### Step 2.5: Verify directive tests pass

Run `mix test test/jido/composer/node/map_node_test.exs`.

## Phase 3: Workflow Integration Test

**Goal**: End-to-end test of a workflow using MapNode.

### Step 3.1: Write integration test

Create `test/integration/workflow_map_node_test.exs`.

Define a simple workflow:

1. `IdentifyItems` action — returns `%{items: ["a", "b", "c"]}`
2. `ProcessItem` action — transforms each item
3. `Aggregate` action — processes the collected results

```elixir
defmodule MapWorkflow do
  use Jido.Composer.Workflow,
    name: "map_workflow",
    nodes: %{
      identify: IdentifyItemsAction,
      process: map_node,      # MapNode over :items
      aggregate: AggregateAction
    },
    transitions: %{
      {:identify, :ok} => :process,
      {:process, :ok} => :aggregate,
      {:aggregate, :ok} => :done,
      {:_, :error} => :failed
    },
    initial: :identify
end
```

Tests:

- Full pipeline runs and produces expected aggregated result
- Empty items list flows through without error
- Element failure triggers error transition
- Concurrency limit is respected (verify via timing or concurrency counter)

### Step 3.2: Verify integration tests pass

Run `mix test test/integration/workflow_map_node_test.exs`.

## Phase 4: DSL Validation and Documentation

### Step 4.1: DSL wrapping support

The Workflow DSL's `__wrap_nodes__/1` function wraps bare action modules into
ActionNodes. It needs to pass MapNode structs through unchanged (same as
FanOutNode):

- MapNode structs should pass through `__wrap_nodes__` without modification
- Add a test for this in the existing DSL validation tests

### Step 4.2: Update design documentation

- Add MapNode to the [Nodes](../nodes/README.md) documentation
- Add MapNode to the [Glossary](../glossary.md)
- Update [Foundations](../foundations.md) to include traverse in the summary
  table
- Update the design [README](../README.md) index

### Step 4.3: Update usage-rules.md

Add MapNode usage examples and patterns to the usage rules reference.

### Step 4.4: Run full quality gate

Run `mix precommit` to verify all checks pass.

## Phase 5 (Follow-Up): Extended Capabilities

These are deferred until the base implementation is proven:

- **AgentNode elements**: MapNode branches that spawn child agents. Requires
  `build_branch_directive` to handle agent modules, similar to FanOutNode.
- **Collect-partial error mode**: Continue processing remaining elements when
  one fails. Reuses FanOut.State's existing `on_error: :collect_partial` path.
- **Element transform function**: An optional function to prepare each element
  before passing to the action. Only add if the map/wrap convention proves
  insufficient.
- **Livebook**: Add a livebook demonstrating the traverse pattern (fits
  naturally after `02_branching_and_parallel.livemd`).

## Files to Create

| File                                          | Purpose                  |
| --------------------------------------------- | ------------------------ |
| `lib/jido/composer/node/map_node.ex`          | MapNode implementation   |
| `test/jido/composer/node/map_node_test.exs`   | MapNode unit tests       |
| `test/integration/workflow_map_node_test.exs` | End-to-end workflow test |

## Files to Modify

| File                                     | Change                                                           |
| ---------------------------------------- | ---------------------------------------------------------------- |
| `lib/jido/composer/workflow/strategy.ex` | Add MapNode clause to `build_node_dispatch_opts/2`               |
| `lib/jido/composer/workflow/dsl.ex`      | Pass MapNode through `__wrap_nodes__/1` (if not already handled) |
| `docs/design/nodes/README.md`            | Add MapNode section                                              |
| `docs/design/glossary.md`                | Add MapNode and Traverse entries                                 |
| `docs/design/foundations.md`             | Add traverse to summary table                                    |
| `docs/design/README.md`                  | Add traverse link                                                |
| `usage-rules.md`                         | Add MapNode usage examples                                       |

## Estimated Size

- **New code**: ~120 lines (MapNode module)
- **New tests**: ~200 lines (unit + integration)
- **Modified code**: ~10 lines (strategy dispatch + DSL wrapping)
- **Documentation**: ~50 lines across existing docs

This is deliberately small. MapNode is a focused, single-purpose node type
that reuses existing infrastructure (FanOutBranch, FanOut.State) rather than
building new abstractions.
