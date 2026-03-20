## Context

Jido Composer provides two composition patterns (Workflow, Orchestrator) that
define agent capabilities at module definition time. The Orchestrator's
`configure/2` already supports runtime overrides for nodes and system_prompt,
but requires the caller to explicitly construct module lists and prompts.

The Skills design (documented at `docs/design/skills/README.md`) introduces
a higher-level abstraction: capability bundles that can be combined at runtime
to create dynamically configured Orchestrator agents. This change implements
the design as two new modules.

### Current State

- Orchestrators define tools via `nodes:` in the DSL or `configure/2` at runtime
- `build_nodes/1` in strategy and configure modules auto-wraps modules as
  ActionNode/AgentNode based on `agent_module?/1` detection
- `AgentTool.to_tool/1` converts nodes to `ReqLLM.Tool` structs
- `query_sync/3` provides synchronous execution for testing
- Test infrastructure: LLMStub for strategy-level tests, ReqCassette for e2e

## Goals / Non-Goals

**Goals:**

- Implement `Jido.Composer.Skill` struct and `Skill.assemble/2` pure function
- Implement `Jido.Composer.Node.DynamicAgentNode` as a Node type
- TDD: write all tests before implementation
- One e2e cassette test with a complex skill configuration mixing actions and
  a sub-agent (Orchestrator or Workflow as a skill tool)
- DynamicAgentNode works as an Orchestrator tool (LLM selects skills)

**Non-Goals:**

- Skill registry beyond inline list (module-based, external discovery)
- `use Jido.Composer.Skill` macro — skills are plain structs
- Skills DSL option on Orchestrator
- Workflow-as-DynamicAgentNode-state (the split assembly/execution pattern) —
  can be done later since `Skill.assemble/2` is public
- Streaming support for assembled agents

## Decisions

### D1: Skill struct is a plain defstruct with enforce_keys

A Skill is pure data. No behaviour, no `use` macro, no validation callbacks.
The struct enforces `[:name, :description, :prompt_fragment, :tools]` via
`@enforce_keys`. Validation (e.g., tools are valid modules) happens in
`assemble/2` where it matters, not in the struct constructor.

**Alternative considered:** A `new/1` constructor with validation. Rejected
because validation at struct creation duplicates work that `configure/2`
already does when building nodes, and forces the caller into a specific
creation path for a plain data type.

### D2: Skill.assemble/2 delegates to a base Orchestrator module + configure/2

Assembly needs an Orchestrator agent to configure. Rather than generating
modules at runtime, we define a single internal base module
(`Jido.Composer.Skill.BaseOrchestrator`) using the Orchestrator DSL with
minimal defaults. `assemble/2` calls `BaseOrchestrator.new()` then
`BaseOrchestrator.configure(agent, ...)` with the composed prompt and tools.

This reuses 100% of the existing Orchestrator infrastructure — node building,
tool conversion, strategy initialization — without any new code paths.

**Alternative considered:** Manually constructing strategy state without the
DSL. Rejected because it would duplicate the node-building and tool-conversion
logic already in `configure.ex`.

### D3: DynamicAgentNode implements Node behaviour directly

DynamicAgentNode is a struct implementing `@behaviour Jido.Composer.Node`
with the standard callbacks. It carries `name`, `description`,
`skill_registry`, and `assembly_opts`. The `run/3` callback:

1. Extracts `skills` and `task` from context (tool call arguments)
2. Looks up matching Skill structs from `skill_registry`
3. Calls `Skill.assemble/2` with the found skills + `assembly_opts`
4. Calls `query_sync` on the assembled agent with `task` as the query
5. Returns the result

The `to_tool_spec/1` callback exposes a schema with `task` (string) and
`skills` (array of strings) so the parent LLM can select skills by name.

### D4: AgentTool.to_tool/1 must handle DynamicAgentNode

The existing `to_tool/1` pattern-matches on `ActionNode` and `AgentNode`.
DynamicAgentNode needs to be added. Since DynamicAgentNode implements
`to_tool_spec/1`, the cleanest approach is to add a generic clause that
delegates to any struct implementing the Node behaviour's `to_tool_spec/1`.
This avoids growing the pattern-match list for every new node type.

### D5: E2e test uses a Workflow sub-agent as one skill's tool

The complex e2e test defines:

- A "math" skill with `AddAction` and `MultiplyAction`
- A "data_pipeline" skill with `TestWorkflowAgent` (a 2-state workflow)
- DynamicAgentNode as a tool in a parent Orchestrator
- The LLM selects skills, the DynamicAgentNode assembles and runs a sub-agent,
  the sub-agent uses the tools (including invoking the Workflow)

This exercises: skill assembly, tool union, prompt composition, mixed node
types (actions + agents), and the full Node contract.

### D6: stream: false enforced during cassette tests

Per existing convention (see `docs/design/testing.md`), streaming bypasses
Req plugs. Assembled agents created during cassette tests must have
`stream: false` in their assembly options, which is already the Orchestrator
default.

## Risks / Trade-offs

**[Risk] Skill name collision with tool names** — If two skills define tools
with the same `name()`, deduplication drops one silently.
→ Mitigation: `assemble/2` deduplicates by module identity, not by name.
Same module appearing in two skills is deduplicated; different modules with
the same name is a configuration error the user must avoid (same as existing
Orchestrator `nodes:` list).

**[Risk] Assembled agent inherits no ambient/fork config** — `Skill.assemble/2`
uses `configure/2` which doesn't set ambient keys or fork functions.
→ Mitigation: Assembly options can include these as pass-through fields. For
the initial implementation, assembled agents don't use ambient/fork — this
matches typical use where the DynamicAgentNode handles context scoping.

**[Trade-off] BaseOrchestrator is a compile-time module** — We need a real
Orchestrator module to call `new()` and `configure()` on. This means one
extra module exists in the library purely for assembly support.
→ Acceptable: it's a minimal, internal module with no public API surface.
