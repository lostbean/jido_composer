## Reference Documents

Read these before implementing:

- **Design**: `docs/design/workflow/README.md` — DSL section: node wrapping, transition validation, agent generation, convenience functions. Compile-time validation table (errors vs warnings)
- **Design**: `docs/design/workflow/strategy.md` — Signal routes table the DSL must auto-generate
- **PLAN.md**: Step 7 — DSL code example showing `use Jido.Composer.Workflow` with full configuration, macro responsibilities list
- **Learnings**: `prototypes/learnings.md` — "DSL Strategy Opts Wiring" confirms `use Jido.Agent, strategy: {Mod, opts}` flow: `strategy/0` returns module, `strategy_opts/0` returns opts keyword. "Module Type Detection" confirms `function_exported?(mod, :run, 2)` for Action vs `function_exported?(mod, :cmd, 2)` for Agent
- **Prototype**: `prototypes/test_dsl_agent_wiring.exs` — 5 tests validating strategy opts flow, module type detection, atom actions in cmd/3, RunInstruction result routing, to_tool conversion

## ADDED Requirements

### Requirement: Workflow DSL generates a Jido.Agent module

`use Jido.Composer.Workflow` SHALL generate a module that uses `Jido.Agent` with the `Workflow.Strategy` and provided configuration.

#### Scenario: Basic workflow definition

- **WHEN** a module uses `Jido.Composer.Workflow` with name, nodes, transitions, and initial state
- **THEN** it SHALL generate a module with `strategy/0` returning `Jido.Composer.Workflow.Strategy` and `strategy_opts/0` returning the configuration

#### Scenario: Auto-wrapping action modules as ActionNodes

- **WHEN** a node value is a bare action module (e.g., `extract: MyAction`)
- **THEN** the DSL SHALL auto-wrap it as `ActionNode.new(MyAction)`

#### Scenario: Auto-wrapping agent modules as AgentNodes

- **WHEN** a node value is a tuple `{MyAgent, mode: :sync}`
- **THEN** the DSL SHALL auto-wrap it as `AgentNode.new(MyAgent, mode: :sync)`

### Requirement: Workflow DSL validates at compile time

The DSL SHALL detect configuration errors at compile time.

#### Scenario: Missing node definition

- **WHEN** a transition references a state that has no node binding (and is not a terminal state)
- **THEN** compilation SHALL raise an error indicating the missing node

#### Scenario: Unreachable state warning

- **WHEN** a node is defined for a state that no transition leads to (and is not the initial state)
- **THEN** compilation SHALL emit a warning about the unreachable state

#### Scenario: Transition references undefined state

- **WHEN** a transition target is neither a defined node state nor a terminal state
- **THEN** compilation SHALL raise an error indicating the undefined target state

### Requirement: Workflow DSL auto-generates signal routes

The generated module SHALL include signal routes for all workflow-related signal types.

#### Scenario: Generated routes match strategy requirements

- **WHEN** the workflow module is compiled
- **THEN** `signal_routes/1` SHALL include routes for workflow start, node results, child lifecycle signals
