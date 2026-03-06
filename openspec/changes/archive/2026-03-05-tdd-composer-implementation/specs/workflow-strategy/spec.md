## Reference Documents

Read these before implementing:

- **Design**: `docs/design/workflow/strategy.md` — Full strategy lifecycle sequence diagram, strategy state fields (machine, module, pending_child, child_request_id), signal routes table, command actions table, execution flow diagrams for ActionNode and AgentNode, FanOutNode handling, error handling rules
- **Design**: `docs/design/workflow/README.md` — High-level workflow architecture, DSL relationship, step-by-step execution flow
- **PLAN.md**: Step 6 — Workflow Strategy code examples, signal route patterns, cmd/3 dispatch on instruction action field
- **Learnings**: `prototypes/learnings.md` — "Signal Routing — No Default Fallback" is critical: every signal type MUST have explicit route. "Instruction action Field Accepts Atoms" confirms strategy-internal actions like `:workflow_start` work. "DirectiveExec Return Types" explains SuspendForHuman must return `{:ok, state}`
- **Prototype**: `prototypes/test_jido_strategy.exs` — 7 tests validating Strategy.State, directives, cmd/3, DirectiveExec, deep merge, emit_to_parent
- **Prototype**: `prototypes/test_dsl_agent_wiring.exs` — Validates strategy opts flow, RunInstruction result routing

## ADDED Requirements

### Requirement: Workflow strategy implements Jido.Agent.Strategy

`Jido.Composer.Workflow.Strategy` SHALL implement the `Jido.Agent.Strategy` behaviour with `init/2`, `cmd/3`, and `signal_routes/1`.

#### Scenario: Strategy initialization builds machine from opts

- **WHEN** `init(agent, %{strategy_opts: opts})` is called with nodes, transitions, and initial state
- **THEN** it SHALL store a `Machine` in `agent.state.__strategy__` and return the updated agent

### Requirement: Strategy dispatches action nodes via RunInstruction

When the current state binds to an ActionNode, the strategy SHALL emit a `RunInstruction` directive.

#### Scenario: Workflow start dispatches first node

- **WHEN** `cmd(agent, [:workflow_start, %{context: ctx}])` is called
- **THEN** the strategy SHALL look up the current state's node, create an Instruction, and emit a `RunInstruction` directive with `result_action: :workflow_node_result`

#### Scenario: Node result triggers transition and dispatches next

- **WHEN** `cmd(agent, [:workflow_node_result, %{result: result}])` is called
- **THEN** the strategy SHALL scope the result under the state name, extract the outcome, apply the transition, and dispatch the next node

### Requirement: Strategy handles agent nodes via SpawnAgent

When the current state binds to an AgentNode, the strategy SHALL emit a `SpawnAgent` directive.

#### Scenario: Agent node dispatches spawn directive

- **WHEN** the current state's node is an AgentNode
- **THEN** the strategy SHALL emit a `SpawnAgent` directive for the agent module

#### Scenario: Child started triggers context delivery

- **WHEN** `cmd(agent, [:workflow_child_started, %{...}])` is called
- **THEN** the strategy SHALL emit a signal containing the current context to the child

#### Scenario: Child result received triggers transition

- **WHEN** `cmd(agent, [:workflow_child_result, %{result: result}])` is called
- **THEN** the strategy SHALL scope result, extract outcome, apply transition, and continue

### Requirement: Strategy reports completion at terminal states

When the machine reaches a terminal state, the strategy SHALL report completion.

#### Scenario: Terminal state reached with success

- **WHEN** a transition leads to `:done`
- **THEN** the strategy SHALL set status to `:success` and include accumulated context as the result

#### Scenario: Terminal state reached with failure

- **WHEN** a transition leads to `:failed`
- **THEN** the strategy SHALL set status to `:failure` and include error information

### Requirement: Strategy declares signal routes

`signal_routes/1` SHALL return mappings for all handled signal types.

#### Scenario: Signal routes cover all workflow signals

- **WHEN** `signal_routes(opts)` is called
- **THEN** it SHALL return routes for `composer.workflow.start`, `composer.workflow.child.result`, `jido.agent.child.started`, and `jido.agent.child.exit`
