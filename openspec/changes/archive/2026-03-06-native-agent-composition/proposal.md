## Why

`AgentNode.run/3` returns `{:error, :not_directly_runnable}`, breaking the Node
behaviour's categorical contract. Every strategy special-cases each node type via
a four-arm case statement, and agents cannot participate in FanOutNode branches.
The demo livebook works around this by wrapping orchestrator agents inside
hand-written Actions. Six interlocking changes restore agents as native
composition blocks.

Design docs updated (a68b542), all proposals validated via prototyping (b2baa01,
29 tests passing across 4 prototype scripts, no design changes needed).

## What Changes

- **Phase 1**: Fix `AgentNode.run/3` to delegate to `run_sync/2` or `query_sync/3` for sync mode, add SpawnAgent handlers in both DSL sync loops
- **Phase 2**: Add `NodeIO` typed envelope wrapping node output (`:map`, `:text`, `:object`), integrate into Machine, Orchestrator, AgentTool, and FanOutNode
- **Phase 3**: Add `Context` struct separating ambient (read-only), working (mutable), and fork functions; thread through Machine and both strategies
- **Phase 4**: Replace inline FanOut execution with `FanOutBranch` directives enabling AgentNode branches, backpressure, and cancellation
- **Phase 5**: Generalize suspension beyond HITL — `Suspension` struct and `Suspend` directive cover rate limits, async completion, external jobs
- **Phase 6**: Implement cascading checkpoint/thaw with schema evolution, `Resume` module, and top-down restore protocol

## Capabilities

### New Capabilities

- Agents (Workflow and Orchestrator) participate as native composition blocks in any context: FanOut branches, nested workflows, tool calls
- Typed I/O adaptation: orchestrators returning text are automatically adapted for map-based deep merge
- Context layers: ambient data (org_id, trace_id) flows read-only through all nesting levels; fork functions transform at agent boundaries
- FanOut branches can contain AgentNodes with backpressure and fail-fast cancellation
- Any node can suspend for any reason (rate limits, async jobs, external webhooks), not just HITL
- Full tree checkpoint/thaw: nested suspended agents persist and restore across process boundaries

### Modified Capabilities

- `AgentNode.run/3` changes from error to sync delegation (Phase 1)
- `Machine.apply_result/2` resolves `NodeIO` envelopes via `to_map/1` (Phase 2)
- Machine `context` field changes from `map()` to `Context.t()` (Phase 3, backward compatible)
- FanOut execution moves from inline to directive-based (Phase 4)
- `pending_approval` replaced by `pending_suspension` in both strategies (Phase 5)
- `SuspendForHuman` becomes a convenience wrapper around generalized `Suspend` (Phase 5)
- Checkpoint format evolves to `:composer_v2` (Phase 6, migration provided)
- `ChildRef` moves from HITL namespace to top-level Composer (Phase 6)

## Scope

### In Scope

- All 6 phases from `native-agent-composition.md`
- TDD approach: tests first, implementation second
- E2E tests with LLMStub first, cassette recording as separate tasks
- Backward compatibility at every phase
- `mix precommit` gate at each phase boundary

### Out of Scope

- Streaming composition model (coalgebraic — documented but deferred)
- Distributed deployment concerns beyond MFA serializability
- External timeout scheduler implementation (library is transport-agnostic)
- Performance optimization for conversations > 1MB (documented escape hatch only)

## Implementation References

- **Design doc**: `native-agent-composition.md` (root)
- **Implementation plan**: `IMPLEMENTATION_PLAN.md` (root)
- **Prototype validation**: `prototypes/learnings.md` (29/29 tests, 4 scripts)
- **Design docs**: `docs/design/nodes/`, `docs/design/workflow/`, `docs/design/orchestrator/`, `docs/design/hitl/`
