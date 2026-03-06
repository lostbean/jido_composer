## Reference Documents

Read these before implementing:

- **Design**: `docs/design/orchestrator/README.md` — DSL section: configuration options table (name, description, llm, nodes, system_prompt, max_iterations, req_options), auto-wrapping rules, generated functions table (new/1, query/3, query_sync/3)
- **Design**: `docs/design/orchestrator/strategy.md` — Signal routes the DSL must auto-generate, strategy state that the DSL configures
- **PLAN.md**: Step 11 — Orchestrator DSL code example with `use Jido.Composer.Orchestrator`
- **Learnings**: `prototypes/learnings.md` — "DSL Strategy Opts Wiring" confirms `use Jido.Agent, strategy: {Mod, opts}` pattern. "Module Type Detection" for auto-wrapping Action vs Agent modules

## ADDED Requirements

### Requirement: Orchestrator DSL generates a Jido.Agent module

`use Jido.Composer.Orchestrator` SHALL generate a module that uses `Jido.Agent` with `Orchestrator.Strategy` and provided configuration.

#### Scenario: Basic orchestrator definition

- **WHEN** a module uses `Jido.Composer.Orchestrator` with name, llm module, nodes, and system prompt
- **THEN** it SHALL generate a module with `strategy/0` returning `Jido.Composer.Orchestrator.Strategy` and `strategy_opts/0` returning the configuration

#### Scenario: Auto-wrapping action modules as ActionNodes

- **WHEN** a node in the list is a bare action module
- **THEN** the DSL SHALL auto-wrap it as `ActionNode.new(module)`

#### Scenario: Auto-wrapping agent modules as AgentNodes

- **WHEN** a node in the list is `{AgentModule, description: "...", mode: :sync}`
- **THEN** the DSL SHALL auto-wrap it as `AgentNode.new(AgentModule, opts)`

### Requirement: Orchestrator DSL auto-generates tool descriptions

The generated module SHALL convert all nodes to tool descriptions at compile time.

#### Scenario: Tools derived from nodes

- **WHEN** the orchestrator module is compiled
- **THEN** `strategy_opts` SHALL include `tools` derived from `AgentTool.to_tool/1` for each node

### Requirement: Orchestrator DSL supports configuration options

The DSL SHALL accept `max_iterations` and `system_prompt` options.

#### Scenario: Default max_iterations

- **WHEN** `max_iterations` is not specified
- **THEN** it SHALL default to `10`

#### Scenario: Custom system prompt

- **WHEN** `system_prompt: "You are a coordinator"` is specified
- **THEN** the strategy opts SHALL include the system prompt
