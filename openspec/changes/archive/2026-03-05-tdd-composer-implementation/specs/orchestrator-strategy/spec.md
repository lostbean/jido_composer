## Reference Documents

Read these before implementing:

- **Design**: `docs/design/orchestrator/strategy.md` — Complete strategy state table, status lifecycle diagram, signal routes table, command actions table, full execution flow sequence diagram, LLM execution via directives (never calls LLM directly), tool execution (ActionNode vs AgentNode), iteration safety, context accumulation rules
- **Design**: `docs/design/orchestrator/README.md` — ReAct loop flowchart, high-level architecture, DSL configuration options
- **Design**: `docs/design/orchestrator/llm-behaviour.md` — How strategy interacts with LLM: passes opaque conversation, req_options propagation
- **Design**: `docs/design/nodes/context-flow.md` — "Context in Orchestrators" section: scope key is tool name, same tool called twice overwrites scope
- **PLAN.md**: Step 10 — Orchestrator Strategy code with full state struct, execution loop description, cmd/3 dispatch table
- **Learnings**: `prototypes/learnings.md` — "Signal Routing — No Default Fallback" critical for orchestrator signal routes. "Instruction action Field Accepts Atoms" confirms internal actions like `:orchestrator_start` work
- **Prototype**: `prototypes/test_jido_strategy.exs` — Strategy.State helpers, directive emission patterns
- **Prototype**: `prototypes/test_llm_tool_calling.exs` — Real tool calling round-trip validates the response parsing the strategy depends on

## ADDED Requirements

### Requirement: Orchestrator strategy implements ReAct loop

`Jido.Composer.Orchestrator.Strategy` SHALL implement `Jido.Agent.Strategy` with a reason-act loop: call LLM, execute tool calls, feed results back, repeat until final answer or limit.

#### Scenario: Single-turn final answer

- **WHEN** `cmd(agent, [:orchestrator_start, %{query: q}])` is called and the LLM returns `{:final_answer, text}`
- **THEN** the strategy SHALL set status to `:success` with the answer as result

#### Scenario: Single tool call round-trip

- **WHEN** the LLM returns `{:tool_calls, [call]}` for an ActionNode
- **THEN** the strategy SHALL emit a `RunInstruction` directive, receive the result, and call LLM again with the tool result

#### Scenario: Multiple tool calls in parallel

- **WHEN** the LLM returns `{:tool_calls, [call1, call2, call3]}`
- **THEN** the strategy SHALL dispatch all tool executions and collect results before the next LLM call

#### Scenario: Multi-turn conversation

- **WHEN** the LLM returns tool calls across multiple iterations
- **THEN** the strategy SHALL pass the updated conversation and accumulated tool results to each subsequent LLM call

### Requirement: Orchestrator enforces iteration limit

The strategy SHALL halt with error when `max_iterations` is reached without a final answer.

#### Scenario: Max iterations exceeded

- **WHEN** the iteration count reaches `max_iterations` without `{:final_answer, _}`
- **THEN** the strategy SHALL set status to `:failure` with an iteration limit error

### Requirement: Orchestrator accumulates context per tool

Each tool execution result SHALL be scoped under the tool name and deep merged into the accumulated context.

#### Scenario: Context scoped per tool name

- **WHEN** tool "search" returns `%{results: [...]}` and tool "summarize" returns `%{summary: "..."}`
- **THEN** the accumulated context SHALL contain `%{search: %{results: [...]}, summarize: %{summary: "..."}}`

#### Scenario: Same tool called twice overwrites scope

- **WHEN** tool "search" is called twice with different results
- **THEN** the second result SHALL deep merge into the existing "search" scope

### Requirement: Orchestrator strategy declares signal routes

`signal_routes/1` SHALL return mappings for all orchestrator signal types.

#### Scenario: Signal routes cover orchestrator signals

- **WHEN** `signal_routes(opts)` is called
- **THEN** it SHALL return routes for `composer.orchestrator.query`, tool results, child lifecycle signals

### Requirement: Orchestrator handles LLM calls via RunInstruction

LLM calls SHALL be dispatched via `RunInstruction` directive using an internal LLM action.

#### Scenario: LLM call emits RunInstruction

- **WHEN** the strategy needs to call the LLM
- **THEN** it SHALL emit a `RunInstruction` with an action that delegates to the configured `llm_module.generate/4`
