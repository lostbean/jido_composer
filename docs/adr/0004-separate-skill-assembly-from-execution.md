# Separate skill assembly from agent execution

<a id="adr-0004"></a>

- Migrated rationale from the existing Skills document; this record is part of the unapproved migration draft.
- Runtime capability selection must remain inspectable without making model calls.
- Skill.assemble therefore composes prompt fragments and deduplicates tool modules into an ordinary configured orchestrator.
- DynamicAgentNode combines assembly and execution for callers needing a single Node operation.
