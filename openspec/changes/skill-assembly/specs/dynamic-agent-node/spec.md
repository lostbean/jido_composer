## ADDED Requirements

### Requirement: DynamicAgentNode struct definition

`Jido.Composer.Node.DynamicAgentNode` SHALL define a struct with enforced keys
`name` (string), `description` (string), `skill_registry` (list of Skill
structs), and optional `assembly_opts` (keyword list, default `[]`).

#### Scenario: Create a DynamicAgentNode with required fields

- **WHEN** a DynamicAgentNode struct is created with name, description, and skill_registry
- **THEN** the struct contains all fields with assembly_opts defaulting to `[]`

#### Scenario: Missing skill_registry raises

- **WHEN** a DynamicAgentNode struct is created without skill_registry
- **THEN** an `ArgumentError` is raised due to `@enforce_keys`

### Requirement: DynamicAgentNode implements Node behaviour

DynamicAgentNode SHALL implement the `Jido.Composer.Node` behaviour with
callbacks `run/3`, `name/1`, `description/1`, `schema/1`, and `to_tool_spec/1`.

#### Scenario: name/1 returns the configured name

- **WHEN** `name/1` is called on a DynamicAgentNode with name "delegate_task"
- **THEN** it returns "delegate_task"

#### Scenario: description/1 returns the configured description

- **WHEN** `description/1` is called on a DynamicAgentNode
- **THEN** it returns the configured description string

#### Scenario: schema/1 returns task and skills parameters

- **WHEN** `schema/1` is called on a DynamicAgentNode
- **THEN** it returns a schema with a required `task` field (string type)
- **THEN** it returns a schema with a required `skills` field (list of strings type)

### Requirement: DynamicAgentNode.to_tool_spec/1

`to_tool_spec/1` SHALL return a map with `name`, `description`, and
`parameter_schema` suitable for LLM tool calling. The parameter_schema SHALL
include `task` (string) and `skills` (array of strings).

#### Scenario: Tool spec has correct structure

- **WHEN** `to_tool_spec/1` is called on a DynamicAgentNode
- **THEN** the result map has keys `:name`, `:description`, `:parameter_schema`
- **THEN** `:parameter_schema` includes a `task` property of type string
- **THEN** `:parameter_schema` includes a `skills` property of type array with string items

### Requirement: AgentTool.to_tool/1 handles DynamicAgentNode

`AgentTool.to_tool/1` SHALL convert a DynamicAgentNode into a `ReqLLM.Tool`
struct, delegating to the node's `to_tool_spec/1`.

#### Scenario: Convert DynamicAgentNode to ReqLLM.Tool

- **WHEN** `AgentTool.to_tool/1` is called with a DynamicAgentNode
- **THEN** it returns a `%ReqLLM.Tool{}` with the node's name and description
- **THEN** the tool's parameter_schema matches the node's to_tool_spec

### Requirement: DynamicAgentNode.run/3 assembles and executes

`run/3` SHALL extract `task` and `skills` from the context, look up matching
Skill structs from the node's `skill_registry` by name, call
`Skill.assemble/2`, execute `query_sync` on the assembled agent, and return
the result.

#### Scenario: Successful run with action-only skills

- **WHEN** `run/3` is called with context `%{task: "Add 1 and 2", skills: ["math"]}` and the skill_registry contains a "math" skill with `AddAction`
- **THEN** the DynamicAgentNode assembles an Orchestrator with the math skill's tools
- **THEN** it executes query_sync with the task
- **THEN** it returns `{:ok, result}` where result contains the execution output

#### Scenario: Unknown skill name returns error

- **WHEN** `run/3` is called with `skills: ["nonexistent"]`
- **THEN** it returns `{:error, reason}` indicating the skill was not found

#### Scenario: Multiple skills combine tools

- **WHEN** `run/3` is called with `skills: ["math", "echo"]` and both skills exist in the registry
- **THEN** the assembled agent has tools from both skills

### Requirement: E2e skill assembly with mixed node types

A DynamicAgentNode used as an Orchestrator tool SHALL support skills whose
tools include both actions and agent modules (Workflows/Orchestrators). The
assembled sub-agent SHALL be able to invoke all tool types.

#### Scenario: Cassette e2e with action and workflow-agent tools

- **WHEN** a parent Orchestrator has a DynamicAgentNode tool
- **WHEN** the DynamicAgentNode's registry includes a "math" skill (with AddAction, MultiplyAction) and a "pipeline" skill (with TestWorkflowAgent)
- **WHEN** the LLM selects the "math" and "pipeline" skills via tool call
- **THEN** the DynamicAgentNode assembles an Orchestrator with AddAction, MultiplyAction, and TestWorkflowAgent as tools
- **THEN** the assembled sub-agent can use AddAction (returns arithmetic result)
- **THEN** the assembled sub-agent can invoke TestWorkflowAgent (runs the 2-state workflow)
- **THEN** the parent Orchestrator receives the sub-agent's final result

#### Scenario: Cassette e2e with action-only skills

- **WHEN** a parent Orchestrator has a DynamicAgentNode tool
- **WHEN** the LLM selects only the "math" skill
- **THEN** the assembled sub-agent has only AddAction and MultiplyAction as tools
- **THEN** the sub-agent executes the task using those tools
- **THEN** the parent receives the result
