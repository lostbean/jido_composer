## Why

jido_composer has complete architectural design and validated prototypes (34 passing tests against real Jido primitives and Claude API), but zero production implementation. The library needs to be built from the ground up following TDD — tests first, then implementation — to ensure every composable building block is deeply validated before composition layers are added on top.

## What Changes

- Implement the `Node` behaviour defining the universal `context -> context` interface
- Implement `ActionNode` adapter wrapping `Jido.Action` modules as Nodes
- Implement `Workflow.Machine` — pure FSM struct with transitions, wildcards, terminal states, scoped deep merge context accumulation, and history tracking
- Implement `Workflow.Strategy` — `Jido.Agent.Strategy` implementation driving deterministic FSM pipelines via directive emission
- Implement `Workflow` DSL — compile-time macro generating workflow agent modules with validation
- Implement `Orchestrator.LLM` behaviour — abstract LLM interface for tool-calling agents
- Implement `ClaudeLLM` reference implementation with cassette-driven tests against Anthropic API
- Implement `AgentTool` adapter — converts Nodes to neutral LLM tool descriptions
- Implement `Orchestrator.Strategy` — ReAct-style loop using LLM behaviour and Node execution
- Implement `Orchestrator` DSL — compile-time macro generating orchestrator agent modules
- Implement `AgentNode` adapter wrapping `Jido.Agent` modules as Nodes (sync/async/streaming modes)
- Implement `FanOutNode` for concurrent branch execution with configurable merge strategies
- Implement workflow + agent nesting (sub-agents as workflow states)
- Implement orchestrator + workflow nesting (workflows as orchestrator tools)
- Implement `HumanNode`, `ApprovalRequest/Response`, `SuspendForHuman` directive for HITL
- Implement HITL integration in both Workflow and Orchestrator strategies
- Implement HITL persistence (checkpoint/thaw/resume)
- Implement nested HITL across composition boundaries
- Create test support infrastructure: stub actions, stub agents, MockLLM, cassette helpers
- Record LLM cassettes for orchestrator tests

## Capabilities

### New Capabilities

- `node-behaviour`: Universal Node behaviour contract (`run/2`, `name/0`, `description/0`, `schema/0`) with outcome-based return types
- `action-node`: ActionNode adapter wrapping Jido.Action modules as Nodes
- `workflow-machine`: Pure FSM struct — transitions, wildcard fallbacks, terminal states, scoped deep merge context accumulation, history
- `workflow-strategy`: Jido.Agent.Strategy for deterministic FSM pipelines — directive emission, signal routing, action/agent node dispatch
- `workflow-dsl`: Compile-time macro for declarative workflow agent definitions with validation
- `llm-behaviour`: Abstract LLM behaviour for orchestrator decision-making — generate/4 callback, conversation state, tool call/result types
- `agent-tool`: Adapter converting Nodes to neutral LLM tool descriptions (JSON Schema)
- `orchestrator-strategy`: ReAct-style agent strategy — LLM-driven tool selection, parallel execution, context accumulation, iteration limits
- `orchestrator-dsl`: Compile-time macro for declarative orchestrator agent definitions
- `agent-node`: AgentNode adapter wrapping Jido.Agent modules as Nodes with sync/async/streaming modes
- `fan-out-node`: Concurrent branch execution Node with configurable merge strategies, fail-fast, timeout
- `composition`: Cross-pattern nesting — workflows containing agents, orchestrators invoking workflows, arbitrary depth
- `hitl`: Human-in-the-loop — HumanNode, ApprovalRequest/Response, SuspendForHuman directive, approval gates, persistence, nested propagation

### Modified Capabilities

## Impact

- **New modules**: ~20 modules under `lib/jido/composer/`
- **New tests**: ~95 tests across unit, integration, and end-to-end layers
- **Dependencies used**: jido, jido_action, jido_signal, deep_merge, zoi, splode, jason, nimble_options, telemetry (all already in mix.exs)
- **Test dependencies**: req_cassette (already in mix.exs)
- **No breaking changes**: Greenfield implementation, no existing public API
- **Cassettes**: LLM interaction recordings stored in `test/cassettes/`
