## Reference Documents

Read these before implementing:

- **Design**: `docs/design/nodes/README.md` — AgentNode section: full struct fields table (agent_module, mode, opts, signal_type, on_state), three communication modes table (sync/async/streaming), sync mode execution steps (5 steps: spawn → child_started → signal → emit_to_parent → merge)
- **Design**: `docs/design/workflow/strategy.md` — "Execution Flow: AgentNode" sequence diagram showing the full parent-child lifecycle
- **Design**: `docs/design/composition.md` — "Communication Across Boundaries" sequence diagram, key properties (signal-based, serializable, hierarchical, isolated)
- **PLAN.md**: Step 4 — AgentNode adapter code with mode handling, sync mode flow description
- **Learnings**: `prototypes/learnings.md` — "SpawnAgent Lifecycle — Confirms AgentNode Design" validates spawn → monitor → child_started → emit_to_parent → child_exit. "on_parent_death Behavior" confirms `:stop` default for cleanup. "Module Type Detection" for agent module validation
- **Prototype**: `prototypes/test_agent_server_children.exs` — 6 tests validating SpawnAgent exec, signal delivery, emit_to_parent, on_parent_death, DOWN monitoring, tag-based lookup

## ADDED Requirements

### Requirement: AgentNode wraps a Jido.Agent module as a Node

`Jido.Composer.Node.AgentNode` SHALL implement the `Node` behaviour and represent a sub-agent that can be invoked within a composition.

#### Scenario: Creating an AgentNode with sync mode

- **WHEN** `AgentNode.new(MyAgent, mode: :sync)` is called
- **THEN** it SHALL return an `%AgentNode{}` struct with mode `:sync`

#### Scenario: Creating an AgentNode with async mode

- **WHEN** `AgentNode.new(MyAgent, mode: :async)` is called
- **THEN** it SHALL return an `%AgentNode{}` struct with mode `:async`

#### Scenario: Default mode is sync

- **WHEN** `AgentNode.new(MyAgent)` is called without mode
- **THEN** the mode SHALL default to `:sync`

#### Scenario: Invalid mode rejected

- **WHEN** `AgentNode.new(MyAgent, mode: :invalid)` is called
- **THEN** it SHALL return `{:error, reason}` indicating invalid mode

#### Scenario: Invalid module rejected

- **WHEN** `AgentNode.new(NotAnAgent)` is called with a non-agent module
- **THEN** it SHALL return `{:error, reason}` indicating the module is not a valid agent

### Requirement: AgentNode metadata delegates to agent module

`name/0`, `description/0`, and `schema/0` SHALL provide metadata from the wrapped agent.

#### Scenario: Name returns agent identifier

- **WHEN** `AgentNode.name(agent_node)` is called
- **THEN** it SHALL return the agent module's name

#### Scenario: Description can be overridden

- **WHEN** `AgentNode.new(MyAgent, description: "Custom description")` is used
- **THEN** `description/0` SHALL return the overridden description

### Requirement: AgentNode supports timeout configuration

AgentNode SHALL accept a `timeout` option for sync mode execution.

#### Scenario: Default timeout

- **WHEN** an AgentNode is created without timeout
- **THEN** the timeout SHALL default to `30_000` milliseconds

#### Scenario: Custom timeout

- **WHEN** `AgentNode.new(MyAgent, timeout: 60_000)` is called
- **THEN** the timeout SHALL be set to `60_000` milliseconds
