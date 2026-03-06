## Reference Documents

Read these before implementing:

- **Design**: `docs/design/nodes/README.md` — ActionNode section: delegation table (name/description/schema), interaction with RunInstruction directive
- **Design**: `docs/design/nodes/context-flow.md` — "Output Scoping" section: scoping is NOT the node's job, it's applied by the composition layer (Machine/Strategy). ActionNode returns raw results
- **PLAN.md**: Step 3 — ActionNode adapter code example, key design note about raw results vs scoped accumulation
- **Learnings**: `prototypes/learnings.md` — "Module Type Detection" confirms `function_exported?(mod, :run, 2)` for Action detection. "Schema Conversion — Already Solved" confirms `Jido.Action.Tool.to_tool/1` exists
- **Prototype**: `prototypes/test_dsl_agent_wiring.exs` — Validates RunInstruction routing pattern that ActionNode relies on

## ADDED Requirements

### Requirement: ActionNode wraps a Jido.Action module as a Node

`Jido.Composer.Node.ActionNode` SHALL implement the `Node` behaviour and delegate execution to a wrapped `Jido.Action` module.

#### Scenario: Creating an ActionNode from an action module

- **WHEN** `ActionNode.new(MyAction, opts)` is called with a valid action module
- **THEN** it SHALL return an `%ActionNode{}` struct containing the action module and options

#### Scenario: Creating an ActionNode with invalid module

- **WHEN** `ActionNode.new(NotAnAction)` is called with a module that does not implement `Jido.Action`
- **THEN** it SHALL return `{:error, reason}` indicating the module is not a valid action

### Requirement: ActionNode.run/2 delegates to the action module

`run/2` SHALL execute the wrapped action via `Jido.Exec.run/4` and return the raw result without scoping.

#### Scenario: Successful action execution

- **WHEN** `ActionNode.run(action_node, context, opts)` is called and the action succeeds
- **THEN** it SHALL return `{:ok, result_map}` with the action's output

#### Scenario: Action returns error

- **WHEN** the wrapped action's execution fails
- **THEN** `run/2` SHALL return `{:error, reason}` from the action

### Requirement: ActionNode metadata delegates to the action module

`name/0`, `description/0`, and `schema/0` SHALL delegate to the wrapped action module's corresponding functions.

#### Scenario: Name delegates to action module

- **WHEN** `ActionNode.name(action_node)` is called
- **THEN** it SHALL return the result of the wrapped action module's `name/0`

#### Scenario: Description delegates to action module

- **WHEN** `ActionNode.description(action_node)` is called
- **THEN** it SHALL return the result of the wrapped action module's `description/0`

#### Scenario: Schema delegates to action module

- **WHEN** `ActionNode.schema(action_node)` is called
- **THEN** it SHALL return the result of the wrapped action module's `schema/0`
