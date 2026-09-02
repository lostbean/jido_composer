# Describe runtime work through Jido directives

<a id="adr-0002"></a>

- Migrated rationale from the existing Overview and strategy documents; this record is part of the unapproved migration draft.
- Runtime effects complicate deterministic strategy testing.
- Strategies therefore describe action execution and child lifecycle work with Jido directives, while AgentServer or a synchronous driver executes them.
- The source's inline termination action and instrumentation effects remain explicit exceptions pending clarification.
