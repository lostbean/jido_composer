## Context

FanOutBranch is the directive emitted when a FanOutNode or MapNode dispatches concurrent branches. Today it carries three mutually exclusive execution mechanisms:

1. `instruction: %Instruction{action: module, params: map}` — for ActionNode branches
2. `spawn_agent: %{agent: module, opts: map}` — for AgentNode branches
3. `instruction: {:function, fun, context}` — for function branches (DSL sync mode only)

Every consumer pattern-matches on these three shapes. MapNode is locked to actions only because it produces `%Instruction{}` directly. Function branches contain closures that break checkpoint serialization and don't work in the agent runtime.

The Node behaviour already provides a uniform `run(node, context, opts) → result` interface. ActionNode, AgentNode, FanOutNode, HumanNode, and MapNode all implement it. The directive should carry the node struct directly.

## Goals / Non-Goals

**Goals:**

- Single execution path: every FanOutBranch dispatches via `child_node.__struct__.run(child_node, params, [])`
- MapNode accepts any Node struct, completing the composition algebra
- All FanOutBranch directives are checkpoint-safe (no closures)
- Backward compatibility for MapNode `:action` option (auto-wraps in ActionNode)

**Non-Goals:**

- Supporting bare functions as FanOutNode branches (breaking change — functions must be wrapped in Action/ActionNode)
- Changing FanOut result collection, merge strategies, or FanOut.State structure
- Modifying the orchestrator strategy (it already rejects FanOutBranch)
- Adding new Node types (FunctionNode, etc.)

## Decisions

### 1. FanOutBranch struct: `child_node` + `params` replaces `instruction` + `spawn_agent`

**New struct:**

```elixir
@enforce_keys [:fan_out_id, :branch_name, :child_node]
defstruct [:fan_out_id, :branch_name, :child_node, :params, :result_action, :timeout]
```

- `child_node` — any struct implementing `Jido.Composer.Node` behaviour
- `params` — the execution context map passed to `child_node.__struct__.run/3`

**Why not keep `instruction` and add `child_node` as a third option?** That would add a fourth variant to pattern-match on. The goal is simplification — one field, one dispatch path.

**Why `params` as a separate field instead of baking into the node?** Nodes are defined once and reused. In MapNode, the same child node runs against different element data. Params vary per-branch; the node struct is constant.

### 2. Drop bare function branches from FanOutNode

FanOutNode currently accepts `{name, struct() | (map() -> result())}`. We remove function support.

**Why:** Functions are the only non-serializable branch type. They only work in DSL sync mode (the agent runtime can't dispatch them). They serve as an escape hatch but break the compositional model.

**Migration:** Users wrap function logic in a `Jido.Action` module + ActionNode. This is a small amount of ceremony for a significant gain in uniformity. The function-as-branch pattern was never documented in usage-rules.md or livebooks.

**Alternative considered:** A FunctionNode that wraps a closure. Rejected because it reintroduces the serialization problem — closures in node structs are still not checkpoint-safe. If needed in the future, it could be added as a separate concern.

### 3. MapNode: `action` field → `node` field with auto-wrapping

MapNode's struct changes from `action: module()` to `node: struct()`. Validation:

- If given a module with `run/2` → auto-wrap in `%ActionNode{action_module: module}`
- If given a struct whose module declares `@behaviour Jido.Composer.Node` → use directly
- Otherwise → error

The `:action` keyword is accepted as a deprecated alias. `:node` takes precedence.

### 4. Execution dispatch is delegated to the Node interface

Both the DSL executor and the strategy dispatch FanOutBranch identically:

```elixir
defp execute_fan_out_branch(%FanOutBranch{child_node: child_node, params: params}) do
  child_node.__struct__.run(child_node, params, [])
end
```

No pattern matching on child type. The Node behaviour contract guarantees `{:ok, map()} | {:ok, map(), outcome} | {:error, term()}`.

AgentNode.run/3 already handles agent spawning internally. No special `spawn_agent` path needed in the directive — the agent lifecycle is AgentNode's responsibility.

### 5. FanOutNode.to_directive/3 simplified

Current `build_branch_directive/6` has three clauses (ActionNode, AgentNode, function). New version:

```elixir
defp build_branch_directive(fan_out_id, branch_name, child_node, params, timeout) do
  %FanOutBranch{
    fan_out_id: fan_out_id,
    branch_name: branch_name,
    child_node: child_node,
    params: params,
    result_action: :fan_out_branch_result,
    timeout: timeout
  }
end
```

One clause. The node struct carries its own execution semantics.

**AgentNode context forking:** Currently `build_branch_directive` does special context forking for AgentNode (`Context.fork_for_child`). This logic moves into `AgentNode.run/3` or stays in `FanOutNode.to_directive/3` as param preparation before building the directive. The directive itself remains uniform.

### 6. No changes to FanOut.State or result handling

FanOut.State stores `queued_branches: [{atom(), FanOutBranch.t()}]`. The struct shape of FanOutBranch changes, but FanOut.State is opaque to it — it just stores and drains tuples. Result handling (`branch_completed`, `branch_suspended`, `branch_error`, `merge_results`) operates on branch names and result values, not on directive internals.

## Risks / Trade-offs

**[Breaking: function branches removed]** → Users with function branches must wrap in Action modules. Mitigated by the fact that function branches are undocumented and only work in DSL sync mode. Search codebase and tests for function branch usage to assess impact.

**[Breaking: FanOutBranch struct fields change]** → Any code directly constructing or pattern-matching on `FanOutBranch.instruction` or `FanOutBranch.spawn_agent` breaks. Mitigated by the fact that these fields are only accessed in FanOutNode, MapNode, and the DSL executor — all within this library.

**[AgentNode context forking]** → Currently done at directive-generation time in FanOutNode. Must ensure it still happens correctly when moved to param preparation. Risk: context forking for AgentNode children in MapNode is a new code path that needs testing.

**[Telemetry metadata]** → Existing telemetry events may reference instruction-level metadata. Verify that moving to node-based dispatch preserves all telemetry attributes.

## Open Questions

- Should `FanOutNode.new/1` validate that all branches are Node structs at creation time, or defer validation to `to_directive/3`? (Recommendation: validate at creation time for fast feedback.)
- Should the `:action` backward-compat alias in MapNode emit a deprecation warning via `IO.warn/1`? (Recommendation: not yet — add in a future release after migration period.)
