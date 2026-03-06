## Phase 1: AgentNode.run/3 Fix

> **References**: `IMPLEMENTATION_PLAN.md` Phase 1. `native-agent-composition.md` §2. `docs/design/nodes/README.md` (AgentNode). `prototypes/test_agent_node_run.exs` (7 tests). `prototypes/learnings.md` §Round 3 findings 1-3.

- [x] 1.1 Write unit tests in `test/jido/composer/node/agent_node_test.exs` — update existing test expecting `{:error, :not_directly_runnable}` to test sync delegation: `run/3` delegates to `run_sync/2` for workflow agents, `run/3` delegates to `query_sync/3` for orchestrator agents, `run/3` returns `{:error, {:not_directly_runnable, :async}}` for async/streaming, `run/3` returns error for agents without sync entry point
- [x] 1.2 Write DSL unit tests — `test/jido/composer/workflow/dsl_test.exs`: `run_sync` handles `SpawnAgent` directives for workflow agents. `test/jido/composer/orchestrator/dsl_test.exs`: `query_sync` handles `SpawnAgent` directives for nested agents (LLMStub plug mode)
- [x] 1.3 Write integration tests — `test/integration/workflow_agent_node_test.exs`: workflow with nested workflow agent completes, workflow with nested orchestrator agent completes (LLMStub). `test/integration/composition_test.exs`: AgentNode in FanOut branch executes successfully
- [x] 1.4 Write e2e test with LLMStub — `test/e2e/e2e_test.exs`: workflow with nested orchestrator via AgentNode.run/3 (LLMStub plug mode)
- [x] 1.5 Add test support agents in `test/support/test_agents.exs` — `TestWorkflowAgent` (2-state: action → done), `TestOrchestratorAgent` (single-tool, for nesting tests)
- [x] 1.6 Implement `AgentNode.run/3` in `lib/jido/composer/node/agent_node.ex` — sync mode delegates to `run_sync/2` or `query_sync/3` via cond chain (`native-agent-composition.md` §2.1)
- [x] 1.7 Add SpawnAgent handler in `lib/jido/composer/workflow/dsl.ex` `run_directives/3` — same pattern as RunInstruction but calls `run_sync` (`native-agent-composition.md` §2.3)
- [x] 1.8 Add SpawnAgent handler in `lib/jido/composer/orchestrator/dsl.ex` `run_orch_directives/3` — same pattern for orchestrator sync loop
- [x] 1.9 Record e2e cassette `e2e_workflow_nested_orchestrator` — delete stub, run `RECORD_CASSETTES=true mix test`, verify replay
- [x] 1.10 PHASE GATE: `mix precommit` — all tests pass, formatting clean, credo clean, docs build

---

## Phase 2: NodeIO Envelope

> **References**: `IMPLEMENTATION_PLAN.md` Phase 2. `native-agent-composition.md` §3. `docs/design/nodes/typed-io.md`. `prototypes/test_node_io_envelope.exs` (7 tests). `prototypes/learnings.md` §Round 3 finding 4 (`@derive Jason.Encoder` needed).

- [x] 2.1 Write unit tests in `test/jido/composer/node_io_test.exs` (NEW) — `map/1` wraps map value, `text/1` wraps string, `object/2` wraps with schema, `to_map/1` passes through map type, `to_map/1` wraps text as `%{text: value}`, `to_map/1` wraps object as `%{object: value}`, `unwrap/1` returns raw value, `mergeable?/1` true only for `:map`, Jason encoding works
- [x] 2.2 Write Machine unit tests in `test/jido/composer/workflow/machine_test.exs` — `apply_result` resolves `NodeIO.text` to map, resolves `NodeIO.object` to map, passes through bare maps unchanged
- [x] 2.3 Write Orchestrator strategy tests in `test/jido/composer/orchestrator/strategy_test.exs` — final answer wraps as `NodeIO.text` (LLMStub direct mode)
- [x] 2.4 Write AgentTool tests in `test/jido/composer/orchestrator/agent_tool_test.exs` — `to_tool_result` unwraps `NodeIO.text` for LLM, unwraps `NodeIO.map` for LLM
- [x] 2.5 Write FanOutNode tests in `test/jido/composer/node/fan_out_node_test.exs` — `merge_results` handles mixed `NodeIO` and bare map branches
- [x] 2.6 Write e2e test — `test/e2e/e2e_test.exs`: nested orchestrator returns text, adapted to map in parent workflow (LLMStub plug mode)
- [x] 2.7 Implement `Jido.Composer.NodeIO` in `lib/jido/composer/node_io.ex` (NEW) — struct with `type`, `value`, `schema`, `meta`; constructors `map/1`, `text/1`, `object/2`; `to_map/1`, `unwrap/1`, `mergeable?/1`; `@derive Jason.Encoder`
- [x] 2.8 Add `resolve_result/1` in `lib/jido/composer/workflow/machine.ex` `apply_result/2` — unwrap `NodeIO` via `to_map/1`, pass through bare maps
- [x] 2.9 Wrap final answers in `lib/jido/composer/orchestrator/strategy.ex` — `{:final_answer, text}` → `NodeIO.text(text)` in `handle_llm_response`
- [x] 2.10 Unwrap NodeIO in `lib/jido/composer/orchestrator/agent_tool.ex` `to_tool_result/3` — text stays string, map stays map
- [x] 2.11 Add NodeIO-aware merge in `lib/jido/composer/node/fan_out_node.ex` `merge_results/2`
- [x] 2.12 Add optional `input_type/1` and `output_type/1` callbacks in `lib/jido/composer/node.ex`
- [x] 2.13 Record e2e cassette `e2e_nodeio_text_adaptation` — delete stub, record, verify replay
- [x] 2.14 PHASE GATE: `mix precommit`

---

## Phase 3: Context Layers

> **References**: `IMPLEMENTATION_PLAN.md` Phase 3. `native-agent-composition.md` §4. `docs/design/nodes/context-flow.md` (Context Layers section). `prototypes/test_context_layering.exs` (8 tests). `prototypes/learnings.md` §Round 3 findings 5-6 (`__ambient__` key, actions read top-level keys).

- [x] 3.1 Write unit tests in `test/jido/composer/context_test.exs` (NEW) — `new/1` empty, `new/1` with all fields, `get_ambient/2`, `apply_result/3` scopes in working, `apply_result/3` doesn't modify ambient, `fork_for_child/1` runs MFA forks, `fork_for_child/1` doesn't modify working, `to_flat_map/1` puts ambient under `__ambient__`, `to_serializable/1` plain map, `from_serializable/1` round-trip, backward compat bare map wrapping
- [x] 3.2 Write Machine unit tests in `test/jido/composer/workflow/machine_test.exs` — `new/1` wraps bare map as Context, `new/1` accepts Context, `apply_result` scopes into `Context.working`
- [x] 3.3 Write Workflow strategy tests in `test/jido/composer/workflow/strategy_test.exs` — dispatch passes flat map to ActionNode, dispatch forks context for AgentNode SpawnAgent
- [x] 3.4 Write Orchestrator strategy tests in `test/jido/composer/orchestrator/strategy_test.exs` — ambient context available in orchestrator (if system prompt interpolation configured)
- [x] 3.5 Write integration tests — `test/integration/workflow_test.exs`: ambient context flows through all workflow states, fork functions run at agent boundaries
- [x] 3.6 Write e2e test — `test/e2e/e2e_test.exs`: multi-level nesting (3 levels) with ambient context flow (LLMStub)
- [x] 3.7 Implement `Jido.Composer.Context` in `lib/jido/composer/context.ex` (NEW) — struct, `new/1`, `get_ambient/2`, `apply_result/3`, `fork_for_child/1`, `to_flat_map/1`, `to_serializable/1`, `from_serializable/1`
- [x] 3.8 Integrate Context into `lib/jido/composer/workflow/machine.ex` — `Context.t()` in context field, backward-compat `new/1`, delegate `apply_result` to Context
- [x] 3.9 Update `lib/jido/composer/workflow/strategy.ex` — `to_flat_map` for ActionNode dispatch, `fork_for_child` for AgentNode SpawnAgent
- [x] 3.10 Update `lib/jido/composer/orchestrator/strategy.ex` — same pattern for tool execution and child spawning
- [x] 3.11 Add `ambient:` and `fork_fns:` DSL options in `lib/jido/composer/workflow/dsl.ex`
- [x] 3.12 Add `ambient:` and `fork_fns:` DSL options in `lib/jido/composer/orchestrator/dsl.ex`
- [x] 3.13 Record e2e cassette `e2e_context_layers_ambient` — delete stub, record, verify replay
- [x] 3.14 PHASE GATE: `mix precommit`

---

## Phase 4: Directive-Based FanOut

> **References**: `IMPLEMENTATION_PLAN.md` Phase 4. `native-agent-composition.md` §5. `docs/design/workflow/strategy.md` (FanOut section). `prototypes/test_fan_out_execution.exs` (8 tests), `prototypes/test_integrated_composition.exs` (mixed FanOut test). `prototypes/learnings.md` — "FanOutNode — Pure Node Implementation", performance (10x speedup).

**Depends on**: Phase 1 (AgentNode.run/3 must work for agent branches)

- [ ] 4.1 Write unit tests in `test/jido/composer/directive/fan_out_branch_test.exs` (NEW) — struct with instruction, struct with spawn_agent, instruction/spawn_agent mutual exclusivity
- [ ] 4.2 Write Workflow strategy tests in `test/jido/composer/workflow/strategy_test.exs` — dispatch FanOutNode emits FanOutBranch directives, `fan_out_branch_result` tracks completion, fan_out completes when all branches done (merge + transition), fail_fast cancels on error, collect_partial continues on error, `max_concurrency` limits dispatch, queued branches dispatch as slots open
- [ ] 4.3 Write DSL tests in `test/jido/composer/workflow/dsl_test.exs` — `run_sync` handles FanOutBranch directives via Task.async_stream
- [ ] 4.4 Write integration tests in `test/integration/workflow_fan_out_test.exs` — FanOut with mixed ActionNode + AgentNode branches, FanOut with orchestrator AgentNode branch (LLMStub), FanOut fail_fast with agent branch failure
- [ ] 4.5 Write e2e test — `test/e2e/e2e_test.exs`: FanOut with mixed agent and action branches (LLMStub plug mode)
- [ ] 4.6 Implement `Jido.Composer.Directive.FanOutBranch` in `lib/jido/composer/directive/fan_out_branch.ex` (NEW) — struct with `fan_out_id`, `branch_name`, `instruction`, `spawn_agent`, `result_action`
- [ ] 4.7 Refactor `lib/jido/composer/workflow/strategy.ex` — replace inline FanOut with directive emission in `dispatch_current_node`, add `pending_fan_out` state, `fan_out_branch_result` handler, `maybe_complete_fan_out`, `cancel_and_fail`, child result routing via tag disambiguation
- [ ] 4.8 Add `max_concurrency` field to `lib/jido/composer/node/fan_out_node.ex`
- [ ] 4.9 Add FanOutBranch handling in `lib/jido/composer/workflow/dsl.ex` `run_directives/3` — execute via Task.async_stream, feed results back through cmd/3
- [ ] 4.10 Add signal route `"composer.fan_out.branch_result"` in both strategies
- [ ] 4.11 Record e2e cassette `e2e_fanout_mixed_agent_action` — delete stub, record, verify replay
- [ ] 4.12 PHASE GATE: `mix precommit`

---

## Phase 5: Generalized Suspension

> **References**: `IMPLEMENTATION_PLAN.md` Phase 5. `native-agent-composition.md` §6. `docs/design/hitl/strategy-integration.md`. `docs/design/hitl/nested-propagation.md`. `prototypes/test_hitl_assumptions.exs` (8 tests), `prototypes/test_integrated_composition.exs` (suspension tests). `prototypes/learnings.md` — "DirectiveExec Return Types" (Suspend must return `{:ok, state}`).

- [ ] 5.1 Write unit tests in `test/jido/composer/suspension_test.exs` (NEW) — `new/1` with required fields, `from_approval_request/1` wraps as `:human_input`, reason types (`:human_input`, `:rate_limit`, `:async_completion`, `:external_job`, `:custom`), Jason encoding
- [ ] 5.2 Write unit tests in `test/jido/composer/directive/suspend_test.exs` (NEW) — struct with suspension, `SuspendForHuman.new` produces generalized Suspend directive
- [ ] 5.3 Write Workflow strategy tests in `test/jido/composer/workflow/strategy_test.exs` — node returning `:suspend` creates Suspension and emits Suspend directive, `suspend_resume` with matching id transitions machine, `suspend_resume` with mismatched id errors, `suspend_timeout` fires timeout outcome, HumanNode backward compat
- [ ] 5.4 Write Orchestrator strategy tests in `test/jido/composer/orchestrator/strategy_test.exs` — non-HITL suspension in tool call, resume continues ReAct loop (LLMStub)
- [ ] 5.5 Write integration tests — `test/integration/workflow_hitl_test.exs`: generalized suspension with rate_limit reason, suspension timeout fires and transitions
- [ ] 5.6 Write e2e test — `test/e2e/e2e_test.exs`: workflow with rate-limit suspension + resume (deterministic + LLMStub orchestrator variant)
- [ ] 5.7 Implement `Jido.Composer.Suspension` in `lib/jido/composer/suspension.ex` (NEW) — struct with id, reason, created_at, resume_signal, timeout, timeout_outcome, metadata, approval_request; `from_approval_request/1`; `@derive Jason.Encoder`
- [ ] 5.8 Implement `Jido.Composer.Directive.Suspend` in `lib/jido/composer/directive/suspend.ex` (NEW) — struct with suspension, notification, hibernate flag
- [ ] 5.9 Refactor `lib/jido/composer/directive/suspend_for_human.ex` — `new/1` produces `Suspend` directive wrapping `Suspension.from_approval_request/1`
- [ ] 5.10 Update `lib/jido/composer/workflow/strategy.ex` — replace `pending_approval` with `pending_suspension`, generalize `dispatch_current_node` to handle any `:suspend` outcome, add `suspend_resume`/`suspend_timeout` handlers, update signal routes
- [ ] 5.11 Update `lib/jido/composer/orchestrator/strategy.ex` — same generalization for tool call suspensions, add `suspended_calls` alongside `gated_calls`
- [ ] 5.12 Record e2e cassette `e2e_generalized_suspension` — delete stub, record, verify replay
- [ ] 5.13 PHASE GATE: `mix precommit`

---

## Phase 6: Persistence Cascade

> **References**: `IMPLEMENTATION_PLAN.md` Phase 6. `native-agent-composition.md` §7. `docs/design/hitl/persistence.md`. `prototypes/test_hitl_assumptions.exs` (serialization, idempotency tests). `prototypes/learnings.md` — "**parent**.pid not stripped by Persist".

**Depends on**: Phase 5 (Generalized Suspension for non-HITL persistence)

- [ ] 6.1 Write unit tests in `test/jido/composer/checkpoint_test.exs` (NEW) — `prepare_for_checkpoint` strips closures (approval_policy → nil), preserves serializable state, `reattach_runtime_config` restores closures from strategy_opts, checkpoint schema version is `:composer_v2`
- [ ] 6.2 Write unit tests for `ChildRef` in `test/jido/composer/child_ref_test.exs` (NEW or extend from `test/jido/composer/hitl/child_ref_test.exs`) — includes `suspension_id` field, status transitions (:running → :paused → :completed), Jason encodable
- [ ] 6.3 Write unit tests in `test/jido/composer/resume_test.exs` (NEW) — `resume/5` delivers signal to live agent, thaws from checkpoint when not live, rejects already-resumed checkpoint (idempotency), returns error for unknown agent
- [ ] 6.4 Write integration tests in `test/integration/hitl_persistence_test.exs` — cascading checkpoint (child before parent), top-down resume (parent thaws, respawns children), fan-out partial completion survives checkpoint, schema migration v1 → v2
- [ ] 6.5 Write e2e test — `test/e2e/e2e_test.exs`: full checkpoint/thaw cycle for nested suspended agent (outer workflow → inner orchestrator suspended → checkpoint → thaw → resume → complete)
- [ ] 6.6 Implement `Jido.Composer.Checkpoint` in `lib/jido/composer/checkpoint.ex` (NEW) — `prepare_for_checkpoint/1` (strip closures), `reattach_runtime_config/2` (restore from strategy_opts), schema v2 definition, migration from v1
- [ ] 6.7 Move and extend `ChildRef` — `lib/jido/composer/child_ref.ex` (from `lib/jido/composer/hitl/child_ref.ex`), add `suspension_id` field, keep alias in HITL namespace for backward compat
- [ ] 6.8 Implement `Jido.Composer.Resume` in `lib/jido/composer/resume.ex` (NEW) — `resume/5` API: find live agent or thaw from checkpoint, deliver resume signal, handle idempotency
- [ ] 6.9 Add checkpoint hooks to `lib/jido/composer/workflow/strategy.ex` — `prepare_for_checkpoint`, `reattach_runtime_config`, ChildRef lifecycle tracking for nested children
- [ ] 6.10 Add checkpoint hooks to `lib/jido/composer/orchestrator/strategy.ex` — closure stripping, conversation offload (optional for large conversations), same ChildRef tracking
- [ ] 6.11 Record e2e cassette `e2e_persistence_cascade_nested` — delete stub, record, verify replay
- [ ] 6.12 PHASE GATE: `mix precommit`
