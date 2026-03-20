## Why

Composer agents are defined at module definition time with fixed tool sets and
system prompts. When the useful capability combinations grow combinatorially
(e.g., mixing web search, code editing, planning, data analysis skills in
different configurations per task), pre-defining every agent is impractical.
We need a runtime assembly mechanism that composes agents from reusable
capability bundles (Skills).

## What Changes

- New `Jido.Composer.Skill` struct — pure data: name, description,
  prompt_fragment, tools (where tools are any Node-compatible module)
- New `Skill.assemble/2` pure function — transforms `[Skill] + opts` into a
  configured Orchestrator agent via prompt composition, tool union, and
  `configure/2`
- New `Jido.Composer.Node.DynamicAgentNode` — Node type that wraps skill
  assembly + execution for use as a tool in Orchestrators or a state in
  Workflows
- Design docs already written at `docs/design/skills/README.md`

## Capabilities

### New Capabilities

- `skill-struct`: The Skill data struct and `Skill.assemble/2` pure function
  (prompt composition, tool union, agent instantiation)
- `dynamic-agent-node`: DynamicAgentNode implementing the Node behaviour —
  skill lookup, assembly delegation, execution, and tool spec generation

### Modified Capabilities

_(none — no existing modules are changed)_

## Impact

- **New modules**: `Jido.Composer.Skill`, `Jido.Composer.Node.DynamicAgentNode`
- **Dependencies**: No new deps — reuses existing Orchestrator `configure/2`,
  AgentTool, Node behaviour, ReqLLM
- **Existing code**: No modifications to existing modules. Skills are additive.
- **Testing**: Unit tests for Skill struct + assemble/2, unit tests for
  DynamicAgentNode, integration test with cassette for e2e assembly + execution
  with mixed tool types (actions + sub-agents)
