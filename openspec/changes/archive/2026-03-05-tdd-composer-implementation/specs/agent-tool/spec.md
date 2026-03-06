## Reference Documents

Read these before implementing:

- **Design**: `docs/design/orchestrator/README.md` — AgentTool Adapter section: three operations table (to_tool, to_context, to_result_message), direction arrows, description of schema conversion delegation
- **Design**: `docs/design/orchestrator/llm-behaviour.md` — Tool description format (name, description, parameters), tool_call format (id, name, arguments), tool_result format (id, name, result)
- **PLAN.md**: Step 9 — AgentTool adapter code with to_tool/1, to_context/1, to_tool_result/3
- **Learnings**: `prototypes/learnings.md` — "Schema Conversion — Already Solved" confirms `Jido.Action.Tool.to_tool/1` and `Jido.Action.Schema.to_json_schema/2` exist in jido_action. No custom conversion code needed — delegate directly
- **Prototype**: `prototypes/test_dsl_agent_wiring.exs` — Test 5 validates `Jido.Action.Tool.to_tool/1` produces correct tool struct from action modules

## ADDED Requirements

### Requirement: AgentTool converts Node to LLM tool description

`Jido.Composer.Orchestrator.AgentTool.to_tool/1` SHALL convert a Node into a neutral tool description with name, description, and JSON Schema parameters.

#### Scenario: Action node to tool conversion

- **WHEN** `to_tool(action_node)` is called on an ActionNode
- **THEN** it SHALL return `%{name: name, description: desc, parameters: json_schema}` using the node's metadata

#### Scenario: Agent node to tool conversion

- **WHEN** `to_tool(agent_node)` is called on an AgentNode
- **THEN** it SHALL return a tool description using the agent's metadata

### Requirement: AgentTool converts tool call arguments to context

`to_context/1` SHALL map LLM tool call arguments back to a context map suitable for Node execution.

#### Scenario: Tool call arguments mapped to context

- **WHEN** `to_context(%{id: id, name: name, arguments: %{"query" => "test"}})` is called
- **THEN** it SHALL return a context map matching the node's expected input format

### Requirement: AgentTool builds normalized tool results

`to_tool_result/3` SHALL create a normalized result struct from node execution output.

#### Scenario: Successful tool result

- **WHEN** `to_tool_result(call_id, node_name, {:ok, result})` is called
- **THEN** it SHALL return `%{id: call_id, name: node_name, result: result}`

#### Scenario: Failed tool result

- **WHEN** `to_tool_result(call_id, node_name, {:error, reason})` is called
- **THEN** it SHALL return `%{id: call_id, name: node_name, result: %{error: reason}}`
