## Why

FanOutBranch complects three execution mechanisms into one directive: `instruction` (for actions), `spawn_agent` (for agents), and `{:function, fun, ctx}` (for closures). This forces every consumer — the DSL executor, the strategy, checkpoint serialization — to pattern-match on instruction shape. It also blocks MapNode from accepting arbitrary Node structs (only actions today), breaking the composition algebra where every other constructor composes nodes uniformly. The closure variant is not serializable for checkpoints and only works in DSL sync mode, not the agent runtime.

## What Changes

- **BREAKING**: Replace `FanOutBranch.instruction` and `FanOutBranch.spawn_agent` fields with a single `child_node` field (any Node struct) plus a `params` field (execution context map).
- **BREAKING**: MapNode's `action` field becomes `node` — accepts any Node struct. Bare action modules auto-wrap in ActionNode for backward compatibility.
- Remove `{:function, fun, ctx}` tuple as an instruction variant. FanOutNode function branches must be wrapped in a lightweight FunctionNode or converted to ActionNode.
- Unify DSL executor (`execute_fan_out_branch/1`) to a single dispatch: `child_node.__struct__.run(child_node, params, [])`.
- Unify strategy dispatch to the same single path — no more three-way pattern match in `build_branch_directive`.
- Checkpoint serialization becomes safe for all branch types since Node structs are pure data (atoms, maps, keywords).

## Capabilities

### New Capabilities

- `node-based-fan-out-branch`: FanOutBranch directive carries a `child_node` (Node struct) + `params` instead of polymorphic instruction/spawn_agent fields. Single dispatch path for execution.
- `map-node-over-nodes`: MapNode accepts any Node struct via `:node` option (not just Action modules). Enables mapping sub-workflows, agents, fan-outs, and human gates over runtime collections.

### Modified Capabilities

## Impact

- `Jido.Composer.Directive.FanOutBranch` — struct fields change (breaking)
- `Jido.Composer.Node.FanOutNode` — `build_branch_directive/6` simplified to produce `child_node` + `params`
- `Jido.Composer.Node.MapNode` — `action` field → `node` field, `to_directive/3` uses new FanOutBranch shape
- `Jido.Composer.Workflow.DSL` — `execute_fan_out_branch/1` unified to single dispatch
- `Jido.Composer.Workflow.Strategy` — fan_out result handling unchanged (operates on branch names/results, not instruction shape)
- `Jido.Composer.FanOut.State` — no structural change (stores directives opaquely in `queued_branches`)
- `Jido.Composer.Checkpoint` — benefits from removal of non-serializable closures; no code change needed
- Test surface: unit tests for FanOutNode, MapNode, FanOutBranch; integration tests for workflows with fan-out; cross-feature tests for HITL + fan-out, checkpoint + fan-out, MapNode + suspend
- Livebooks: `02_branching_and_parallel`, `09_traverse_and_mapping`, `10_composition_patterns` need updates
