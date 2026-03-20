## ADDED Requirements

### Requirement: Skill struct definition

The `Jido.Composer.Skill` module SHALL define a struct with enforced keys
`name` (string), `description` (string), `prompt_fragment` (string), and
`tools` (list of modules).

#### Scenario: Create a skill with all required fields

- **WHEN** a Skill struct is created with name, description, prompt_fragment, and tools
- **THEN** the struct contains all four fields with the provided values

#### Scenario: Missing required field raises

- **WHEN** a Skill struct is created without the `name` field
- **THEN** an `ArgumentError` is raised due to `@enforce_keys`

#### Scenario: Missing tools field raises

- **WHEN** a Skill struct is created without the `tools` field
- **THEN** an `ArgumentError` is raised due to `@enforce_keys`

### Requirement: Skill.assemble/2 produces a configured Orchestrator

`Skill.assemble/2` SHALL accept a list of Skill structs and a keyword list of
assembly options, and return `{:ok, agent}` where `agent` is a
`Jido.Agent` struct configured as an Orchestrator with the combined prompt and
tools from the provided skills.

#### Scenario: Assemble with a single skill

- **WHEN** `Skill.assemble/2` is called with one skill containing two action tools and `base_prompt: "You are a helper."`, `model: "anthropic:claude-sonnet-4-20250514"`
- **THEN** it returns `{:ok, agent}` where `agent` is a `%Jido.Agent{}`
- **THEN** the agent's strategy state system_prompt contains the base_prompt text
- **THEN** the agent's strategy state system_prompt contains the skill's prompt_fragment
- **THEN** `get_action_modules(agent)` includes both action modules from the skill

#### Scenario: Assemble with multiple skills composes prompts

- **WHEN** `Skill.assemble/2` is called with two skills
- **THEN** the agent's strategy state system_prompt contains both skills' prompt_fragments
- **THEN** `get_action_modules(agent)` includes tools from both skills

#### Scenario: Assemble deduplicates shared tools

- **WHEN** two skills both include `AddAction` in their tools
- **THEN** `get_action_modules(agent)` contains `AddAction` exactly once

#### Scenario: Assemble with agent module as tool

- **WHEN** a skill's tools list includes a Workflow agent module (e.g., `TestWorkflowAgent`)
- **THEN** `get_action_modules(agent)` includes that agent module
- **THEN** the assembled agent treats it as an AgentNode tool (detected via `agent_module?/1`)

#### Scenario: Assemble with empty skill list

- **WHEN** `Skill.assemble/2` is called with an empty list of skills
- **THEN** it returns `{:ok, agent}` with an agent that has no tools configured
- **THEN** the system prompt contains only the base_prompt

#### Scenario: Assembly options pass through to configure

- **WHEN** `Skill.assemble/2` is called with options `max_iterations: 5`, `temperature: 0.3`
- **THEN** the agent's strategy state reflects `max_iterations: 5` and `temperature: 0.3`

### Requirement: Prompt composition format

`Skill.assemble/2` SHALL compose the system prompt by placing the base_prompt
first, followed by a "## Capabilities" header, then each skill's
prompt_fragment separated by blank lines.

#### Scenario: Prompt structure with two skills

- **WHEN** assembling with base_prompt "You are a specialist." and two skills with fragments "Search the web." and "Edit code."
- **THEN** the system prompt starts with "You are a specialist."
- **THEN** the system prompt contains "## Capabilities"
- **THEN** the system prompt contains "Search the web."
- **THEN** the system prompt contains "Edit code."

#### Scenario: Prompt with nil base_prompt

- **WHEN** `Skill.assemble/2` is called without a `:base_prompt` option
- **THEN** the system prompt starts directly with "## Capabilities" and the skill fragments
