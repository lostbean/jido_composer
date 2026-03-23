## 1. FanOutBranch Directive Refactor (TDD: tests first)

- [x] 1.1 Write tests for new FanOutBranch struct: `child_node` + `params` fields, enforce_keys, typespec. Verify old `instruction`/`spawn_agent` fields no longer exist.
- [x] 1.2 Write serialization round-trip tests: FanOutBranch with ActionNode, AgentNode, FanOutNode, HumanNode children all survive `:erlang.term_to_binary` → `:erlang.binary_to_term`.
- [x] 1.3 Implement FanOutBranch struct change: replace `instruction`/`spawn_agent` with `child_node`/`params`.

## 2. FanOutNode: Node-Only Branches (TDD: tests first)

- [x] 2.1 Write tests for FanOutNode.new/1 rejecting bare function branches, accepting only Node structs.
- [x] 2.2 Write tests for FanOutNode.to_directive/3 producing FanOutBranch with `child_node` for ActionNode, AgentNode, and mixed branch types.
- [x] 2.3 Write test for FanOutNode.to_directive/3 with nested FanOutNode as branch child.
- [x] 2.4 Update FanOutNode.new/1: validate all branches are Node structs (not functions). Update branch type.
- [x] 2.5 Update FanOutNode.to_directive/3: replace `build_branch_directive/6` three-clause dispatch with single-clause that sets `child_node` + `params`. Handle AgentNode context forking in param preparation.
- [x] 2.6 Update FanOutNode.run/3: remove `execute_branch` function-clause, rely on `%mod{} = node -> mod.run(node, context)` only.

## 3. MapNode: Accept Any Node (TDD: tests first)

- [x] 3.1 Write tests for MapNode.new/1: accepts bare action module (auto-wrap), ActionNode, FanOutNode, AgentNode, HumanNode. Rejects invalid values. `:action` backward compat, `:node` precedence.
- [x] 3.2 Write tests for MapNode.run/3: ActionNode child produces same results as before. FanOutNode child maps fan-out over collection. Empty collection returns `%{results: []}`.
- [x] 3.3 Write tests for MapNode.to_directive/3: produces FanOutBranch with `child_node` for ActionNode and FanOutNode children. Verify max_concurrency splits into dispatched/queued.
- [x] 3.4 Write tests for MapNode.description/1 using child node dispatch_name.
- [x] 3.5 Implement MapNode struct change: `action` → `node`, add `resolve_node/1` with auto-wrapping.
- [x] 3.6 Implement MapNode.run/3: dispatch through `child_node.__struct__.run/3`.
- [x] 3.7 Implement MapNode.to_directive/3: use new FanOutBranch with `child_node` + `params`.

## 4. DSL Executor Update

- [x] 4.1 Write test for DSL `execute_fan_out_branch/1` dispatching via `child_node.__struct__.run/3` (ActionNode, AgentNode branches).
- [x] 4.2 Update `execute_fan_out_branch/1` in workflow/dsl.ex: remove three-clause pattern match, replace with single `child_node.__struct__.run(child_node, params, [])`.
- [x] 4.3 Verify existing DSL run_sync tests pass with new dispatch.

## 5. Workflow Strategy Alignment

- [x] 5.1 Verify strategy `cmd/3` for `:fan_out_branch_result` is unaffected (operates on branch names/results, not directive internals).
- [x] 5.2 Verify `dispatch_queued_branches/1` and `FanOut.State.drain_queue/1` work with new FanOutBranch shape (they're opaque to directive contents).
- [x] 5.3 Verify strategy `build_node_dispatch_opts/2` still provides correct opts for FanOutNode and MapNode.

## 6. Cross-Feature Integration Tests (TDD)

- [x] 6.1 Write integration test: FanOutNode in workflow with ActionNode branches — full lifecycle (dispatch, result collection, transition).
- [x] 6.2 Write integration test: FanOutNode with AgentNode branch in workflow — agent spawning, result collection.
- [x] 6.3 Write integration test: MapNode with ActionNode child in workflow pipeline (generate → map → aggregate).
- [x] 6.4 Write integration test: MapNode with FanOutNode child — node-over-node composition in workflow.
- [x] 6.5 Write integration test: MapNode with HumanNode child — per-element suspension and resume.

## 7. Checkpoint/Persistence Integration Tests (TDD)

- [x] 7.1 Write test: checkpoint FanOutBranch with ActionNode child in queued_branches — round-trip serialization.
- [x] 7.2 Write test: checkpoint FanOutBranch with AgentNode child in queued_branches — round-trip serialization.
- [x] 7.3 Write test: checkpoint MapNode mid-execution with queued branches — restore and continue.
- [x] 7.4 Write test: checkpoint MapNode with FanOutNode child — verify nested node struct survives checkpoint.
- [x] 7.5 Verify `strip_for_checkpoint/1` has no closures to strip in fan-out state (all data now).

## 8. HITL + Fan-Out Integration Tests (TDD)

- [x] 8.1 Write test: FanOutNode with HumanNode branch — suspension, approval, resume, completion.
- [x] 8.2 Write test: FanOutNode with mix of ActionNode and HumanNode branches — partial suspension.
- [x] 8.3 Write test: MapNode with HumanNode child — per-element suspension, sequential approval, ordered results.
- [x] 8.4 Write test: suspended fan-out branch with timeout — timeout fires, branch errors, fan-out completes.

## 9. Telemetry / Observability

- [x] 9.1 Verify existing telemetry events for fan-out branch execution still fire correctly with node-based dispatch.
- [x] 9.2 Add node type to fan-out branch telemetry metadata if not already present.

## 10. Existing Test Migration

- [x] 10.1 Update all existing FanOutNode tests that reference `instruction:` or `spawn_agent:` fields to use `child_node:`/`params:`.
- [x] 10.2 Update all existing MapNode tests that reference `node.action` to use `node.node`.
- [x] 10.3 Update existing integration tests (workflow_fan_out_test, workflow_map_node_test, hitl_persistence_test) for new struct shapes.
- [x] 10.4 Update cross-feature tests (workflow_map_node_cross_feature_test) for new struct shapes.
- [x] 10.5 Run `mix precommit` — full suite green.

## 11. Documentation and Livebooks

- [x] 11.1 Update usage-rules.md: MapNode `:node` option, FanOutNode node-only branches, FanOutBranch new shape.
- [x] 11.2 Update livebook 02_branching_and_parallel: remove any function branch examples, use ActionNode.
- [x] 11.3 Update livebook 09_traverse_and_mapping: show MapNode with `:node` option, add node-over-node example.
- [x] 11.4 Update livebook 10_composition_patterns: demonstrate MapNode composing with FanOutNode and other nodes.
- [x] 11.5 Verify all non-LLM livebooks run: `mix run scripts/run_livemd.exs livebooks/0[1-3]*.livemd` and livebooks 09, 10.

## 12. Cleanup

- [x] 12.1 Remove prototype worktree if still present.
- [x] 12.2 Run `mix precommit` — final green.
