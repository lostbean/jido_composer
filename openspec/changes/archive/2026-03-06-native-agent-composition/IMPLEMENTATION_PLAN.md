# Native Agent Composition — TDD Implementation Plan

**Status**: Ready for implementation
**Design ref**: `native-agent-composition.md`
**Prototype validation**: `prototypes/learnings.md` (29/29 tests passing, no design changes)

---

## Overview

Six phases restore agents as native composition blocks. Each phase follows
strict TDD: write tests first, verify they fail, implement, verify they pass,
run `mix precommit`.

**E2E strategy**: LLMStub plug mode first (no API key), cassette recording as a
separate task within each phase.

---

## Phase 1: AgentNode.run/3 Fix

**Goal**: Restore the categorical contract — `AgentNode.run/3` returns
`{:ok, result}` for sync mode instead of `{:error, :not_directly_runnable}`.

**Design refs**:

- `native-agent-composition.md` §2
- `docs/design/nodes/README.md` (AgentNode section)

### Tests First

#### 1.1 Unit tests — `test/jido/composer/node/agent_node_test.exs`

Update existing test that expects `{:error, :not_directly_runnable}`:

- `"run/3 delegates to run_sync/2 for workflow agents"` — Create a minimal
  workflow agent, call `AgentNode.run/3`, assert `{:ok, result}` with expected
  context shape
- `"run/3 delegates to query_sync/3 for orchestrator agents"` — Create a minimal
  orchestrator agent, call `AgentNode.run/3` with `%{query: "test"}`, assert
  `{:ok, %{result: _}}`
- `"run/3 returns error for async/streaming modes"` — Assert
  `{:error, {:not_directly_runnable, :async}}` and same for `:streaming`
- `"run/3 returns error for non-sync-runnable agents"` — Agent without
  `run_sync/2` or `query_sync/3`

#### 1.2 Unit tests — DSL SpawnAgent handling

**`test/jido/composer/workflow/dsl_test.exs`**:

- `"run_sync handles SpawnAgent directives for workflow agents"` — Define a
  workflow with an AgentNode step, call `run_sync/2`, assert result includes
  child agent output scoped under state name

**`test/jido/composer/orchestrator/dsl_test.exs`**:

- `"query_sync handles SpawnAgent directives for nested agents"` — Define an
  orchestrator with a nested agent tool, call `query_sync/3` (LLMStub returns
  tool_call for the agent), assert tool result flows back

#### 1.3 Integration tests

**`test/integration/workflow_agent_node_test.exs`** (extend):

- `"workflow with nested workflow agent completes full pipeline"` — Outer
  workflow has a state bound to an inner workflow agent. Run to completion.
- `"workflow with nested orchestrator agent completes"` — Same but inner is
  orchestrator (LLMStub)

**`test/integration/composition_test.exs`** (extend):

- `"AgentNode in FanOut branch executes successfully"` — FanOutNode with
  mixed ActionNode + AgentNode branches, all complete

#### 1.4 E2E test — `test/e2e/e2e_test.exs` (extend)

- `"e2e: workflow with nested orchestrator via AgentNode.run/3"` — Full pipeline:
  outer workflow → inner orchestrator (LLMStub first)

#### 1.5 Test support — `test/support/test_agents.exs`

Add minimal test agents:

- `TestWorkflowAgent` — simple 2-state workflow (action → done)
- `TestOrchestratorAgent` — single-tool orchestrator for nesting tests

### Implementation

1. **`lib/jido/composer/node/agent_node.ex`** — Replace `run/3` stub with sync
   delegation (§2.1 of design doc)
2. **`lib/jido/composer/workflow/dsl.ex`** — Add `SpawnAgent` clause in
   `run_directives/3` (§2.3)
3. **`lib/jido/composer/orchestrator/dsl.ex`** — Add `SpawnAgent` clause in
   `run_orch_directives/3` (§2.3)
4. **`test/support/test_agents.exs`** — Add test agents

### Phase Gate

```bash
mix precommit
```

---

## Phase 2: NodeIO Envelope

**Goal**: Typed I/O envelope wrapping node output. Orchestrator text results
become mergeable maps via `to_map/1`.

**Design refs**:

- `native-agent-composition.md` §3
- `docs/design/nodes/typed-io.md`

### Tests First

#### 2.1 Unit tests — `test/jido/composer/node_io_test.exs` (NEW)

- `"map/1 wraps a map value"` — `NodeIO.map(%{a: 1})` has type `:map`
- `"text/1 wraps a string value"` — `NodeIO.text("hello")` has type `:text`
- `"object/2 wraps with optional schema"` — type `:object`, schema preserved
- `"to_map/1 passes through map type"` — `to_map(map(%{a: 1}))` == `%{a: 1}`
- `"to_map/1 wraps text as %{text: value}"` — `to_map(text("hi"))` ==
  `%{text: "hi"}`
- `"to_map/1 wraps object as %{object: value}"` — structured output
- `"unwrap/1 returns raw value for all types"`
- `"mergeable?/1 returns true only for :map type"`
- `"Jason encoding works"` — `@derive Jason.Encoder` on struct

#### 2.2 Unit tests — Machine resolve_result

**`test/jido/composer/workflow/machine_test.exs`** (extend):

- `"apply_result resolves NodeIO.text to map"` — Machine receives
  `NodeIO.text("answer")`, context gets `%{state_name: %{text: "answer"}}`
- `"apply_result resolves NodeIO.object to map"` — Same for object
- `"apply_result passes through bare maps unchanged"` — Backward compat

#### 2.3 Unit tests — Orchestrator wrapping

**`test/jido/composer/orchestrator/strategy_test.exs`** (extend):

- `"final answer wraps as NodeIO.text"` — After LLM returns final_answer,
  strategy result is `NodeIO.text(...)` (LLMStub)

#### 2.4 Unit tests — AgentTool unwrap

**`test/jido/composer/orchestrator/agent_tool_test.exs`** (extend):

- `"to_tool_result unwraps NodeIO.text for LLM"` — Text stays as string
- `"to_tool_result unwraps NodeIO.map for LLM"` — Map stays as map

#### 2.5 Unit tests — FanOutNode merge

**`test/jido/composer/node/fan_out_node_test.exs`** (extend):

- `"merge_results handles mixed NodeIO and bare map branches"` — Heterogeneous
  merge

#### 2.6 E2E test

- `"e2e: nested orchestrator returns text, adapted to map in workflow"` —
  Orchestrator child returns text, parent workflow merges correctly (LLMStub)

### Implementation

1. **`lib/jido/composer/node_io.ex`** (NEW) — NodeIO struct with constructors,
   `to_map/1`, `unwrap/1`, `mergeable?/1`, `@derive Jason.Encoder`
2. **`lib/jido/composer/workflow/machine.ex`** — Add `resolve_result/1` in
   `apply_result/2`
3. **`lib/jido/composer/orchestrator/strategy.ex`** — Wrap `{:final_answer, text}`
   as `NodeIO.text(text)`
4. **`lib/jido/composer/orchestrator/agent_tool.ex`** — Unwrap NodeIO in
   `to_tool_result/3`
5. **`lib/jido/composer/node/fan_out_node.ex`** — NodeIO-aware `merge_results/2`
6. **`lib/jido/composer/node.ex`** — Add optional `input_type/1`, `output_type/1`
   callbacks

### Phase Gate

```bash
mix precommit
```

---

## Phase 3: Context Layers

**Goal**: Separate ambient (read-only), working (mutable), and fork functions in
context. Backward compatible — nodes still receive `map()`.

**Design refs**:

- `native-agent-composition.md` §4
- `docs/design/nodes/context-flow.md`

### Tests First

#### 3.1 Unit tests — `test/jido/composer/context_test.exs` (NEW)

- `"new/1 creates empty context"` — Defaults to empty ambient/working/fork_fns
- `"new/1 accepts ambient, working, fork_fns"` — All fields populated
- `"get_ambient/2 reads from ambient layer"` — Returns value or nil
- `"apply_result/3 scopes result under key in working"` — Deep merge
- `"apply_result/3 does not modify ambient"` — Ambient unchanged after apply
- `"fork_for_child/1 runs all fork functions on ambient"` — MFA forks execute
- `"fork_for_child/1 does not modify working"` — Working unchanged
- `"to_flat_map/1 merges ambient under __ambient__ key"` — Flat map shape
- `"to_serializable/1 produces plain map"` — MFA tuples preserved
- `"from_serializable/1 round-trips"` — Serialize → deserialize == original
- `"backward compat: bare map wraps as Context with working"` — Machine.new

#### 3.2 Unit tests — Machine integration

**`test/jido/composer/workflow/machine_test.exs`** (extend):

- `"new/1 wraps bare map context into Context struct"` — Backward compat
- `"new/1 accepts Context struct directly"` — Pass-through
- `"apply_result scopes into Context.working"` — After apply, working updated,
  ambient unchanged

#### 3.3 Unit tests — Strategy integration

**`test/jido/composer/workflow/strategy_test.exs`** (extend):

- `"dispatch passes flat map to ActionNode"` — Node receives
  `%{__ambient__: ...}`
- `"dispatch forks context for AgentNode"` — SpawnAgent opts include forked
  context

**`test/jido/composer/orchestrator/strategy_test.exs`** (extend):

- `"ambient context available in system prompt interpolation"` — If configured

#### 3.4 Integration tests

**`test/integration/workflow_test.exs`** (extend):

- `"ambient context flows through all workflow states"` — org_id available at
  every step
- `"fork functions run at agent boundaries"` — Correlation ID changes per level

#### 3.5 E2E test

- `"e2e: multi-level nesting with ambient context flow"` — 3-level nesting,
  ambient flows down, working accumulates (LLMStub)

### Implementation

1. **`lib/jido/composer/context.ex`** (NEW) — Context struct, `new/1`,
   `get_ambient/2`, `apply_result/3`, `fork_for_child/1`, `to_flat_map/1`,
   serialization
2. **`lib/jido/composer/workflow/machine.ex`** — Context.t() in `context` field,
   backward-compat `new/1`
3. **`lib/jido/composer/workflow/strategy.ex`** — `to_flat_map` for ActionNode,
   `fork_for_child` for AgentNode
4. **`lib/jido/composer/orchestrator/strategy.ex`** — Same pattern
5. **`lib/jido/composer/workflow/dsl.ex`** — `ambient:`, `fork_fns:` DSL options
6. **`lib/jido/composer/orchestrator/dsl.ex`** — Same

### Phase Gate

```bash
mix precommit
```

---

## Phase 4: Directive-Based FanOut

**Goal**: FanOutNode becomes a pure data descriptor. Strategy decomposes into
individual `FanOutBranch` directives. Supports AgentNode branches.

**Design refs**:

- `native-agent-composition.md` §5
- `docs/design/workflow/strategy.md` (FanOut section)

**Depends on**: Phase 1 (AgentNode.run/3)

### Tests First

#### 4.1 Unit tests — `test/jido/composer/directive/fan_out_branch_test.exs` (NEW)

- `"struct construction with instruction"` — ActionNode branch
- `"struct construction with spawn_agent"` — AgentNode branch
- `"instruction and spawn_agent are mutually exclusive"` — Validation

#### 4.2 Unit tests — Strategy FanOut

**`test/jido/composer/workflow/strategy_test.exs`** (extend):

- `"dispatch FanOutNode emits FanOutBranch directives"` — One per branch
- `"fan_out_branch_result tracks completion"` — Result stored, branch removed
  from pending
- `"fan_out completes when all branches done"` — Merge + transition
- `"fail_fast cancels remaining branches on error"` — Cancel directives emitted
- `"collect_partial continues on branch error"` — Error stored, flow continues
- `"max_concurrency limits dispatched branches"` — Only N dispatched initially
- `"queued branches dispatch as slots open"` — FIFO dispatch after completion

#### 4.3 Unit tests — DSL handling

**`test/jido/composer/workflow/dsl_test.exs`** (extend):

- `"run_sync handles FanOutBranch directives"` — Executes branches locally via
  Task.async_stream, feeds results back

#### 4.4 Integration tests

**`test/integration/workflow_fan_out_test.exs`** (extend):

- `"FanOut with mixed ActionNode + AgentNode branches"` — Both types complete
- `"FanOut with AgentNode branch that is orchestrator"` — Nested LLM call
  (LLMStub)
- `"FanOut fail_fast with agent branch failure"` — Agent error triggers cancel

#### 4.5 E2E test

- `"e2e: FanOut with mixed agent and action branches"` — Full pipeline with
  parallel step (LLMStub)

### Implementation

1. **`lib/jido/composer/directive/fan_out_branch.ex`** (NEW) — FanOutBranch
   struct
2. **`lib/jido/composer/workflow/strategy.ex`** — Replace inline FanOut execution
   with directive emission, add `fan_out_branch_result` handler, completion
   tracking, cancellation, backpressure
3. **`lib/jido/composer/node/fan_out_node.ex`** — Add `max_concurrency` field
4. **`lib/jido/composer/workflow/dsl.ex`** — FanOutBranch handling in
   `run_directives/3`

### Phase Gate

```bash
mix precommit
```

---

## Phase 5: Generalized Suspension

**Goal**: Suspension beyond HITL — rate limits, async completion, external jobs.
Existing HITL becomes a special case.

**Design refs**:

- `native-agent-composition.md` §6
- `docs/design/hitl/strategy-integration.md`
- `docs/design/hitl/nested-propagation.md`

### Tests First

#### 5.1 Unit tests — `test/jido/composer/suspension_test.exs` (NEW)

- `"new/1 creates suspension with required fields"` — id, reason, created_at
- `"from_approval_request/1 creates :human_input suspension"` — Wraps existing
  ApprovalRequest
- `"reason types"` — `:human_input`, `:rate_limit`, `:async_completion`,
  `:external_job`, `:custom`
- `"Jason encoding works"` — `@derive Jason.Encoder`

#### 5.2 Unit tests — `test/jido/composer/directive/suspend_test.exs` (NEW)

- `"struct construction with suspension"` — Required field
- `"SuspendForHuman.new produces Suspend directive"` — Backward compat wrapper

#### 5.3 Unit tests — Strategy suspend/resume

**`test/jido/composer/workflow/strategy_test.exs`** (extend):

- `"node returning :suspend creates Suspension and emits Suspend directive"` —
  Generic node
- `"suspend_resume with matching id transitions machine"` — Resume with outcome
- `"suspend_resume with mismatched id returns error"` — ID mismatch
- `"suspend_timeout fires timeout outcome"` — Configurable timeout transition
- `"HumanNode suspend still works (backward compat)"` — Existing HITL path

**`test/jido/composer/orchestrator/strategy_test.exs`** (extend):

- `"non-HITL suspension in orchestrator tool call"` — Rate limit suspension
- `"resume continues orchestrator ReAct loop"` — After rate limit resume

#### 5.4 Integration tests

**`test/integration/workflow_hitl_test.exs`** (extend):

- `"generalized suspension with rate limit reason"` — Workflow suspends for
  rate_limit, resumes with data
- `"suspension timeout fires and transitions"` — Timeout outcome

#### 5.5 E2E test

- `"e2e: workflow with rate-limit suspension and resume"` — Deterministic
  workflow with custom suspending node + resume (LLMStub for orchestrator
  variant)

### Implementation

1. **`lib/jido/composer/suspension.ex`** (NEW) — Suspension struct,
   `from_approval_request/1`
2. **`lib/jido/composer/directive/suspend.ex`** (NEW) — Generalized Suspend
   directive
3. **`lib/jido/composer/directive/suspend_for_human.ex`** — Refactor to produce
   `Suspend` directive wrapping `Suspension.from_approval_request/1`
4. **`lib/jido/composer/workflow/strategy.ex`** — Replace `pending_approval` with
   `pending_suspension`, generalize `dispatch_current_node/1` suspension
   handling, add `suspend_resume`/`suspend_timeout` handlers
5. **`lib/jido/composer/orchestrator/strategy.ex`** — Same generalization for
   tool call suspensions

### Phase Gate

```bash
mix precommit
```

---

## Phase 6: Persistence Cascade

**Goal**: Full tree checkpoint/thaw with schema evolution. Cascading checkpoint
for nested suspended agents. Top-down resume.

**Design refs**:

- `native-agent-composition.md` §7
- `docs/design/hitl/persistence.md`

**Depends on**: Phase 5 (Generalized Suspension)

### Tests First

#### 6.1 Unit tests — `test/jido/composer/checkpoint_test.exs` (NEW)

- `"prepare_for_checkpoint strips closures"` — approval_policy → nil
- `"prepare_for_checkpoint preserves serializable state"` — MFA, atoms, maps
- `"reattach_runtime_config restores closures from strategy_opts"` — Round-trip
- `"checkpoint schema version is :composer_v2"` — Version field

#### 6.2 Unit tests — `test/jido/composer/child_ref_test.exs` (NEW or extend)

- `"ChildRef includes suspension_id field"` — Links to Suspension
- `"ChildRef status transitions"` — :running → :paused → :completed
- `"ChildRef is Jason encodable"` — Serialization

#### 6.3 Unit tests — `test/jido/composer/resume_test.exs` (NEW)

- `"resume/5 delivers signal to live agent"` — Agent in memory
- `"resume/5 thaws from checkpoint when not live"` — Checkpoint → start → resume
- `"resume/5 rejects already-resumed checkpoint"` — Idempotency
- `"resume/5 returns error for unknown agent"` — Not found

#### 6.4 Integration tests

**`test/integration/hitl_persistence_test.exs`** (extend):

- `"cascading checkpoint: child checkpoints before parent"` — Order validation
- `"top-down resume: parent thaws, respawns children"` — Full cycle
- `"fan-out partial completion survives checkpoint"` — Completed + suspended
  branches preserved
- `"schema migration from v1 to v2"` — Legacy checkpoint restored

#### 6.5 E2E test

- `"e2e: full checkpoint/thaw cycle for nested suspended agent"` — Outer
  workflow → inner orchestrator suspended → checkpoint both → thaw → resume →
  complete

### Implementation

1. **`lib/jido/composer/checkpoint.ex`** (NEW) — `prepare_for_checkpoint/1`,
   `reattach_runtime_config/2`, checkpoint schema v2
2. **`lib/jido/composer/child_ref.ex`** — Move from `hitl/child_ref.ex`, extend
   with `suspension_id`
3. **`lib/jido/composer/resume.ex`** (NEW) — `resume/5` API, thaw-and-resume
   logic
4. **`lib/jido/composer/workflow/strategy.ex`** — Checkpoint hooks, restore hooks,
   ChildRef lifecycle tracking
5. **`lib/jido/composer/orchestrator/strategy.ex`** — Closure stripping,
   conversation offload, checkpoint hooks

### Phase Gate

```bash
mix precommit
```

---

## Cassette Recording Tasks

Each phase includes an optional cassette recording task after the LLMStub-based
tests pass. These are separate from the core TDD flow:

| Phase | Cassette Name                      | Scenario                                |
| ----- | ---------------------------------- | --------------------------------------- |
| 1     | `e2e_workflow_nested_orchestrator` | Workflow with nested orchestrator agent |
| 2     | `e2e_nodeio_text_adaptation`       | Orchestrator text → map adaptation      |
| 3     | `e2e_context_layers_ambient`       | Multi-level nesting with ambient flow   |
| 4     | `e2e_fanout_mixed_agent_action`    | FanOut with mixed agent/action branches |
| 5     | `e2e_generalized_suspension`       | Rate-limit suspension + resume          |
| 6     | `e2e_persistence_cascade_nested`   | Full checkpoint/thaw nested cycle       |

To record: delete existing cassette, run `RECORD_CASSETTES=true mix test`.

---

## Dependency Graph

```
Phase 1 (AgentNode.run/3) ──┬──→ Phase 2 (NodeIO) ──→ Phase 3 (Context)
                             │
                             └──→ Phase 4 (FanOut) ──→ Phase 5 (Suspension) ──→ Phase 6 (Persistence)
```

Phases 2 and 4 can proceed in parallel after Phase 1. Phase 3 depends on Phase 2. Phases 5 and 6 are sequential.

---

## Prototype Validation

All six proposals were validated in `prototypes/` (commit b2baa01):

| Script                            | Tests | Status   |
| --------------------------------- | ----- | -------- |
| `test_agent_node_run.exs`         | 7     | ALL PASS |
| `test_node_io_envelope.exs`       | 7     | ALL PASS |
| `test_context_layering.exs`       | 8     | ALL PASS |
| `test_integrated_composition.exs` | 7     | ALL PASS |

See `prototypes/learnings.md` for findings and performance numbers.
