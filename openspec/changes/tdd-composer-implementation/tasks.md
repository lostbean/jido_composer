## 1. Project Scaffold & Test Support

> **References**: `PLAN.md` Step 1 (project scaffold). `docs/design/testing.md` — test directory structure, cassette helper patterns, sensitive data filters. `prototypes/learnings.md` — all sections provide patterns for test helpers.

- [x] 1.1 Create `lib/jido/composer/` directory structure matching PLAN.md file layout
- [x] 1.2 Create `Jido.Composer` top-level module with moduledoc (replace placeholder)
- [x] 1.3 Create `test/support/test_actions.ex` with stub action modules (AddAction, MultiplyAction, FailAction, SlowAction, etc.)
- [x] 1.4 Create `test/support/test_agents.ex` with stub agent modules for composition tests
- [x] 1.5 Create `test/support/cassette_helper.ex` with centralized sensitive data filters and cassette setup helpers
- [x] 1.6 Update `test/test_helper.exs` to configure ExUnit and load support modules

## 2. Error Module

> **References**: `docs/design/glossary.md` — error terminology. `PLAN.md` — error.ex in file structure. Uses Splode for structured errors (see `mix.exs` dependency `{:splode, "~> 0.3.0"}`). Moved early because Node, Machine, Strategy, and all subsequent modules need Composer-specific error types.

- [x] 2.1 Write tests for Composer-specific error types in `test/jido/composer/error_test.exs`
- [x] 2.2 Implement `Jido.Composer.Error` in `lib/jido/composer/error.ex` using Splode

---

**PHASE GATE: run `mix precommit` — scaffold and error foundation must pass before proceeding.**

---

## 3. Node Behaviour

> **References**: `docs/design/nodes/README.md` — Node contract, callbacks table, design decisions. `docs/design/nodes/context-flow.md` — scoped accumulation, deep merge semantics. `docs/design/foundations.md` — monoid laws, Kleisli arrows. `PLAN.md` Step 2. `prototypes/learnings.md` — "Module Type Detection".

- [x] 3.1 Write tests for Node behaviour contract in `test/jido/composer/node_test.exs` (callback enforcement, return types)
- [x] 3.2 Implement `Jido.Composer.Node` behaviour in `lib/jido/composer/node.ex` (callbacks, types)

## 4. ActionNode

> **References**: `docs/design/nodes/README.md` — ActionNode section, delegation table. `docs/design/nodes/context-flow.md` — "Output Scoping": scoping is NOT ActionNode's job. `PLAN.md` Step 3. `prototypes/learnings.md` — "Schema Conversion — Already Solved", "Module Type Detection". `prototypes/test_dsl_agent_wiring.exs` — RunInstruction routing.

- [x] 4.1 Write tests for ActionNode in `test/jido/composer/node/action_node_test.exs` (new/2, run/2, metadata delegation, invalid module rejection)
- [x] 4.2 Implement `Jido.Composer.Node.ActionNode` in `lib/jido/composer/node/action_node.ex`

## 5. Workflow Machine

> **References**: `docs/design/workflow/state-machine.md` — Machine struct, operations, transition lookup diagram, terminal states. `docs/design/nodes/context-flow.md` — "Context in Workflows", scope key is state name. `docs/design/foundations.md` — monoid laws. `PLAN.md` Step 5. `prototypes/learnings.md` — "Deep Merge Lists Overwrite", performance (617K transitions/sec). `prototypes/test_fsm_deep_merge.exs` — 7 tests for reference.

- [x] 5.1 Write tests for Machine in `test/jido/composer/workflow/machine_test.exs` (new/1, transition/2 with fallback chain, terminal detection, apply_result/3 scoping, history tracking)
- [x] 5.2 Implement `Jido.Composer.Workflow.Machine` in `lib/jido/composer/workflow/machine.ex`

## 6. Workflow Strategy

> **References**: `docs/design/workflow/strategy.md` — Full lifecycle diagram, strategy state fields, signal routes, command actions, ActionNode/AgentNode/FanOutNode execution flows, error handling. `docs/design/workflow/README.md` — high-level architecture. `PLAN.md` Step 6. `prototypes/learnings.md` — "Signal Routing — No Default Fallback" (CRITICAL), "Instruction action Field Accepts Atoms", "DirectiveExec Return Types". `prototypes/test_jido_strategy.exs` — Strategy.State, directives. `prototypes/test_dsl_agent_wiring.exs` — strategy opts, RunInstruction routing.

- [x] 6.1 Write tests for Workflow.Strategy in `test/jido/composer/workflow/strategy_test.exs` (init/2, cmd/3 for workflow_start, workflow_node_result, terminal state handling, signal_routes/1)
- [x] 6.2 Implement `Jido.Composer.Workflow.Strategy` in `lib/jido/composer/workflow/strategy.ex`

## 7. Workflow DSL

> **References**: `docs/design/workflow/README.md` — DSL section: node wrapping, transition validation (errors vs warnings table), agent generation, convenience functions. `PLAN.md` Step 7. `prototypes/learnings.md` — "DSL Strategy Opts Wiring" (`use Jido.Agent, strategy: {Mod, opts}`), "Module Type Detection" (`function_exported?`). `prototypes/test_dsl_agent_wiring.exs` — 5 tests on strategy opts flow.

- [x] 7.1 Write tests for Workflow DSL in `test/jido/composer/workflow/dsl_test.exs` (module generation, auto-wrapping, compile-time validation)
- [x] 7.2 Implement `Jido.Composer.Workflow.DSL` in `lib/jido/composer/workflow/dsl.ex`

## 8. Workflow Integration Tests

> **References**: `docs/design/testing.md` — Integration tests table (linear workflow, branching, error handling, nested). `docs/design/workflow/README.md` — ETL pipeline state diagram example. `docs/design/nodes/context-flow.md` — full scoped accumulation flow. `docs/design/use-cases.md` — concrete workflow scenarios.

- [x] 8.1 Write integration tests in `test/integration/workflow_test.exs` (linear pipeline, branching, error handling, context isolation)
- [x] 8.2 Fix any issues discovered during integration testing

---

**PHASE GATE: run `mix precommit` — full Workflow track (Node, ActionNode, Machine, Strategy, DSL, integration) must pass before proceeding.**

---

## 9. LLM Behaviour & ClaudeLLM Reference

> **References**: `docs/design/orchestrator/llm-behaviour.md` — Complete generate/4 contract, response types, conversation ownership, req_options propagation, implementation requirements (7 items), testing approach. `docs/design/testing.md` — ReqCassette integration, streaming constraint, sensitive data filtering, req_options propagation path. `PLAN.md` Steps 8-10. `prototypes/learnings.md` — "Schema Conversion — Already Solved". `prototypes/test_llm_tool_calling.exs` — 5 tests against real Claude API.

- [x] 9.1 Write tests for LLM behaviour contract in `test/jido/composer/orchestrator/llm_test.exs`
- [x] 9.2 Implement `Jido.Composer.Orchestrator.LLM` behaviour in `lib/jido/composer/orchestrator/llm.ex`
- [x] 9.3 Record cassettes for ClaudeLLM: single tool call, multi-turn, final answer, API error
- [x] 9.4 Write cassette-driven tests for ClaudeLLM in `test/jido/composer/orchestrator/claude_llm_test.exs`
- [x] 9.5 Implement `Jido.Composer.Orchestrator.ClaudeLLM` in `lib/jido/composer/orchestrator/claude_llm.ex`

## 10. AgentTool Adapter

> **References**: `docs/design/orchestrator/README.md` — AgentTool adapter section: three operations (to_tool, to_context, to_result_message), schema conversion delegation. `docs/design/orchestrator/llm-behaviour.md` — tool/tool_call/tool_result format tables. `PLAN.md` Step 9. `prototypes/learnings.md` — "Schema Conversion — Already Solved" (`Jido.Action.Tool.to_tool/1`, `Jido.Action.Schema.to_json_schema/2`). `prototypes/test_dsl_agent_wiring.exs` — Test 5 validates to_tool conversion.

- [x] 10.1 Write tests for AgentTool in `test/jido/composer/orchestrator/agent_tool_test.exs` (to_tool/1, to_context/1, to_tool_result/3)
- [x] 10.2 Implement `Jido.Composer.Orchestrator.AgentTool` in `lib/jido/composer/orchestrator/agent_tool.ex`

## 11. Orchestrator Strategy

> **References**: `docs/design/orchestrator/strategy.md` — Strategy state table, status lifecycle diagram, signal routes, command actions, execution flow sequence diagram, LLM via directives, tool execution rules, context accumulation. `docs/design/orchestrator/llm-behaviour.md` — opaque conversation, req_options. `docs/design/nodes/context-flow.md` — "Context in Orchestrators". `PLAN.md` Step 10. `prototypes/learnings.md` — "Signal Routing — No Default Fallback", "Instruction action Field Accepts Atoms". `prototypes/test_jido_strategy.exs` — Strategy.State, directives. `prototypes/test_llm_tool_calling.exs` — tool calling round-trip.

- [x] 11.1 Create `test/support/mock_llm.ex` with MockLLM returning predetermined responses for strategy state machine tests
- [x] 11.2 Write tests for Orchestrator.Strategy in `test/jido/composer/orchestrator/strategy_test.exs` (single-turn, tool call round-trip, multi-tool parallel, max iterations, context accumulation, signal_routes/1)
- [x] 11.3 Implement `Jido.Composer.Orchestrator.Strategy` in `lib/jido/composer/orchestrator/strategy.ex`

## 12. Orchestrator DSL

> **References**: `docs/design/orchestrator/README.md` — DSL section: config options table, generated functions table (new/1, query/3, query_sync/3). `PLAN.md` Step 11. `prototypes/learnings.md` — "DSL Strategy Opts Wiring", "Module Type Detection".

- [ ] 12.1 Write tests for Orchestrator DSL in `test/jido/composer/orchestrator/dsl_test.exs` (module generation, auto-wrapping, tool generation, defaults)
- [ ] 12.2 Implement `Jido.Composer.Orchestrator.DSL` in `lib/jido/composer/orchestrator/dsl.ex`

## 13. Orchestrator Integration Tests

> **References**: `docs/design/testing.md` — Integration/E2E test tables. `docs/design/orchestrator/strategy.md` — full ReAct loop execution. `docs/design/use-cases.md` — orchestrator scenarios.

- [ ] 13.1 Write cassette-driven integration tests in `test/integration/orchestrator_test.exs` (full ReAct loop with ClaudeLLM cassettes)
- [ ] 13.2 Fix any issues discovered during integration testing

---

**PHASE GATE: run `mix precommit` — full Orchestrator track (LLM, AgentTool, Strategy, DSL, integration) must pass before proceeding.**

---

## 14. AgentNode

> **References**: `docs/design/nodes/README.md` — AgentNode section: struct fields, three modes table, sync mode 5-step flow. `docs/design/workflow/strategy.md` — "Execution Flow: AgentNode" sequence diagram. `docs/design/composition.md` — communication across boundaries. `PLAN.md` Step 4. `prototypes/learnings.md` — "SpawnAgent Lifecycle", "on_parent_death Behavior", "Module Type Detection". `prototypes/test_agent_server_children.exs` — 6 lifecycle tests.

- [ ] 14.1 Write tests for AgentNode in `test/jido/composer/node/agent_node_test.exs` (struct construction, mode validation, metadata delegation, timeout defaults)
- [ ] 14.2 Implement `Jido.Composer.Node.AgentNode` in `lib/jido/composer/node/agent_node.ex`

## 15. FanOutNode

> **References**: `docs/design/nodes/README.md` — FanOutNode section: struct fields, execution steps, merge strategies, error handling, relationship to `&&&` combinator. `docs/design/workflow/strategy.md` — "Execution Flow: FanOutNode". `docs/design/foundations.md` — "Arrow Combinators: Parallel and Fan-Out". `prototypes/learnings.md` — "FanOutNode — Pure Node Implementation" (Task.async_stream confirmed). `prototypes/test_fan_out_execution.exs` — 8 tests including 10x speedup.

- [ ] 15.1 Write tests for FanOutNode in `test/jido/composer/node/fan_out_node_test.exs` (concurrent execution, merge strategies, fail-fast, timeout, single branch)
- [ ] 15.2 Implement `Jido.Composer.Node.FanOutNode` in `lib/jido/composer/node/fan_out_node.ex`

## 16. Workflow + AgentNode Composition

> **References**: `docs/design/composition.md` — Supported compositions table, communication sequence diagram, key properties. `docs/design/workflow/strategy.md` — AgentNode execution flow. `docs/design/nodes/context-flow.md` — "Context Across Agent Boundaries" (serializable, no PIDs). `prototypes/test_agent_server_children.exs` — full SpawnAgent lifecycle.

- [ ] 16.1 Write tests in `test/integration/workflow_agent_node_test.exs` (sub-agent in workflow, context across boundary, failure handling)
- [ ] 16.2 Update Workflow.Strategy to handle AgentNode dispatch (SpawnAgent, child_started, child_result)
- [ ] 16.3 Fix any issues discovered during composition testing

## 17. Workflow + FanOutNode Composition

> **References**: `docs/design/workflow/strategy.md` — "Execution Flow: FanOutNode" (FanOutNode is no different from ActionNode to the strategy). `docs/design/nodes/README.md` — FanOutNode "When to use" guidance. `prototypes/test_fan_out_execution.exs` — concurrent execution patterns.

- [ ] 17.1 Write tests in `test/integration/workflow_fan_out_test.exs` (FanOutNode in FSM state, merged result feeds transition)
- [ ] 17.2 Fix any issues discovered during composition testing

## 18. Cross-Pattern Nesting

> **References**: `docs/design/composition.md` — Full nesting patterns diagram, all 8 supported compositions, depth/recursion analysis. `docs/design/orchestrator/strategy.md` — "Tool Execution" for ActionNode vs AgentNode tools. `docs/design/foundations.md` — "Nesting as Functorial Embedding". `PLAN.md` Step 12 — nesting example code. `prototypes/learnings.md` — context serialization size (36 KB for 10 nodes). `prototypes/test_agent_server_children.exs` — SpawnAgent lifecycle.

- [ ] 18.1 Write cassette-driven tests in `test/integration/composition_test.exs` (orchestrator invokes workflow-as-tool, workflow result as tool result)
- [ ] 18.2 Write end-to-end test for three-level nesting (orchestrator -> workflow -> agent)
- [ ] 18.3 Fix any issues discovered during nesting tests

---

**PHASE GATE: run `mix precommit` — full Composition track (AgentNode, FanOutNode, nesting, cross-pattern) must pass before proceeding.**

---

## 19. HITL Structs

> **References**: `docs/design/hitl/approval-lifecycle.md` — ApprovalRequest full 14-field table (who sets each), ApprovalResponse fields, protocol sequence diagram. `docs/design/hitl/human-node.md` — how HumanNode constructs ApprovalRequest. `prototypes/test_hitl_assumptions.exs` — serialization, approval gate tests.

- [ ] 19.1 Write tests for ApprovalRequest in `test/jido/composer/hitl/approval_request_test.exs` (creation, auto-id, serialization)
- [ ] 19.2 Write tests for ApprovalResponse in `test/jido/composer/hitl/approval_response_test.exs` (creation, validation)
- [ ] 19.3 Implement ApprovalRequest in `lib/jido/composer/hitl/approval_request.ex`
- [ ] 19.4 Implement ApprovalResponse in `lib/jido/composer/hitl/approval_response.ex`

## 20. HumanNode

> **References**: `docs/design/hitl/human-node.md` — HumanNode struct fields, run/2 contract (`{:ok, ctx, :suspend}`), prompt evaluation, context filtering. `docs/design/hitl/README.md` — "Humans Are Nodes" principle. `docs/design/nodes/README.md` — HumanNode in Node type hierarchy. `prototypes/test_hitl_assumptions.exs` — suspend/resume, rejection tests.

- [ ] 20.1 Write tests for HumanNode in `test/jido/composer/node/human_node_test.exs` (suspend outcome, static/dynamic prompt, context filtering)
- [ ] 20.2 Implement `Jido.Composer.Node.HumanNode` in `lib/jido/composer/node/human_node.ex`

## 21. SuspendForHuman Directive

> **References**: `docs/design/hitl/strategy-integration.md` — SuspendForHuman directive fields table (approval_request, notification, hibernate), runtime interpretation (3 steps). `prototypes/learnings.md` — "DirectiveExec Return Types": SuspendForHuman MUST return `{:ok, state}` (NOT `{:stop, ...}` which hard-stops agent).

- [ ] 21.1 Write tests for SuspendForHuman directive in `test/jido/composer/directive/suspend_for_human_test.exs`
- [ ] 21.2 Implement `Jido.Composer.Directive.SuspendForHuman` in `lib/jido/composer/directive/suspend_for_human.ex`

## 22. Workflow + HumanNode Integration

> **References**: `docs/design/hitl/strategy-integration.md` — Workflow suspend/resume flow, signal routes for HITL, timeout via Schedule directive. `docs/design/hitl/approval-lifecycle.md` — ApprovalResponse validation, decision as outcome. `prototypes/test_hitl_assumptions.exs` — suspend/resume cycle, timeout tests.

- [ ] 22.1 Write tests in `test/integration/workflow_hitl_test.exs` (suspend/resume cycle, timeout outcome transition)
- [ ] 22.2 Update Workflow.Strategy to handle `:suspend` outcome and resume signal
- [ ] 22.3 Fix any issues discovered during HITL workflow testing

## 23. Orchestrator Approval Gate

> **References**: `docs/design/hitl/strategy-integration.md` — Orchestrator approval gate: partition tool calls (gated vs ungated), mixed states (`awaiting_tools_and_approval`), rejection handling (synthetic tool result injection), rejection policy options (`:continue_siblings`, `:cancel_siblings`, `:abort_iteration`). `prototypes/test_hitl_assumptions.exs` — approval gate partition, rejection tests.

- [ ] 23.1 Write tests in `test/integration/orchestrator_hitl_test.exs` (gated tool call, mixed gated/ungated, rejection with synthetic result)
- [ ] 23.2 Update Orchestrator.Strategy to support `requires_approval` metadata and approval gates
- [ ] 23.3 Fix any issues discovered during approval gate testing

## 24. HITL Persistence

> **References**: `docs/design/hitl/persistence.md` — Hybrid lifecycle diagram, what gets checkpointed, ParentRef PID handling (strip pid on checkpoint, re-inject on resume), ChildRef struct, top-down resume protocol, idempotent resume (status field + compare-and-swap), schema evolution. `prototypes/learnings.md` — strategy state serialization 422 bytes. `prototypes/test_hitl_assumptions.exs` — serialization, ParentRef, ChildRef, idempotency tests.

- [ ] 24.1 Write tests in `test/integration/hitl_persistence_test.exs` (checkpoint serialization, thaw from checkpoint, idempotent resume, ChildRef)
- [ ] 24.2 Implement ChildRef struct and checkpoint/thaw logic
- [ ] 24.3 Fix any issues discovered during persistence testing

## 25. Nested HITL Integration

> **References**: `docs/design/hitl/nested-propagation.md` — Reference scenario (OuterWorkflow -> InnerOrchestrator with HITL gate), parent isolation, concurrent work during child pause, cascading checkpoint/resume, cascading cancellation, multiple HITL points. `docs/design/composition.md` — "HITL Across Composition Boundaries" section. `prototypes/test_hitl_assumptions.exs` — nested HITL assumption tests.

- [ ] 25.1 Write tests in `test/integration/hitl_integration_test.exs` (child suspend isolation, cascading checkpoint, top-down resume)
- [ ] 25.2 Fix any issues discovered during nested HITL testing

---

**PHASE GATE: run `mix precommit` — full HITL track (structs, HumanNode, directive, workflow HITL, orchestrator approval gate, persistence, nested) must pass. All 65 tasks complete.**

---
