## Reference Documents

- **Design**: `native-agent-composition.md` §4 — Context layering, Reader monad, fork functions, 3-level nesting
- **Design**: `docs/design/nodes/context-flow.md` — Context Layers section, ambient/working/fork separation
- **Prototype**: `prototypes/test_context_layering.exs` — 8 passing tests
- **Learnings**: `prototypes/learnings.md` — "**ambient** key", "actions read top-level keys"
- **PLAN**: `IMPLEMENTATION_PLAN.md` Phase 3

## ADDED Requirements

### Requirement: Context struct separates ambient, working, and fork layers

`Jido.Composer.Context` SHALL be a struct with three fields: `ambient` (read-only map), `working` (mutable map), and `fork_fns` (map of MFA tuples).

#### Scenario: Create empty context

- **WHEN** `Context.new()` is called
- **THEN** it SHALL return `%Context{ambient: %{}, working: %{}, fork_fns: %{}}`

#### Scenario: Create context with all layers

- **WHEN** `Context.new(ambient: %{org_id: "acme"}, working: %{data: 1}, fork_fns: %{otel: {M, :f, []}})` is called
- **THEN** all three layers SHALL be populated

### Requirement: Ambient context is read-only through composition

`Context.apply_result/3` SHALL only modify the working layer; ambient SHALL remain unchanged.

#### Scenario: apply_result preserves ambient

- **WHEN** `Context.apply_result(ctx, :step1, %{value: 42})` is called
- **THEN** `ctx.ambient` SHALL be unchanged
- **AND** `ctx.working` SHALL contain `%{step1: %{value: 42}}`

### Requirement: Fork functions transform ambient at agent boundaries

`Context.fork_for_child/1` SHALL execute all fork functions, producing a new ambient for the child context.

#### Scenario: Fork runs MFA tuples

- **GIVEN** `fork_fns: %{correlation: {Forks, :new_correlation, []}}`
- **WHEN** `Context.fork_for_child(ctx)` is called
- **THEN** the returned context SHALL have `ambient.correlation_id` set by the fork function
- **AND** working SHALL be unchanged

### Requirement: to_flat_map produces backward-compatible map

`Context.to_flat_map/1` SHALL merge ambient under `__ambient__` key into the working map.

#### Scenario: Flat map shape

- **GIVEN** `Context{ambient: %{org_id: "acme"}, working: %{data: 1}}`
- **WHEN** `Context.to_flat_map(ctx)` is called
- **THEN** it SHALL return `%{data: 1, __ambient__: %{org_id: "acme"}}`

### Requirement: Context is serializable

`Context.to_serializable/1` and `Context.from_serializable/1` SHALL round-trip without data loss.

#### Scenario: Serialize and restore

- **WHEN** a Context with ambient, working, and MFA fork_fns is serialized and restored
- **THEN** the restored Context SHALL equal the original

## MODIFIED Requirements

### Requirement: Machine context field accepts Context struct

`Machine.new/1` SHALL accept both bare `map()` (backward compatible) and `Context.t()`.

#### Scenario: Bare map wraps as Context

- **WHEN** `Machine.new(context: %{input: "data"})` is called
- **THEN** the machine context SHALL be `%Context{working: %{input: "data"}, ambient: %{}, fork_fns: %{}}`

#### Scenario: Context passes through

- **WHEN** `Machine.new(context: %Context{ambient: %{org_id: "acme"}})` is called
- **THEN** the machine context SHALL be the provided Context

### Requirement: Workflow strategy passes flat map to action nodes

When dispatching an ActionNode, the Workflow strategy SHALL call `Context.to_flat_map/1` to produce the node's input.

#### Scenario: ActionNode receives **ambient**

- **WHEN** the strategy dispatches an ActionNode
- **THEN** the RunInstruction params SHALL include `__ambient__` key from `to_flat_map`

### Requirement: Workflow strategy forks context for agent nodes

When dispatching an AgentNode via SpawnAgent, the Workflow strategy SHALL call `Context.fork_for_child/1` before serializing.

#### Scenario: Child receives forked ambient

- **WHEN** the strategy emits SpawnAgent with fork functions configured
- **THEN** the SpawnAgent opts context SHALL contain the forked ambient

### Requirement: DSL supports ambient and fork_fns options

Both Workflow and Orchestrator DSLs SHALL accept `ambient:` (key list) and `fork_fns:` (MFA map) options.

#### Scenario: Ambient keys extracted on start

- **GIVEN** `use Jido.Composer.Workflow, ambient: [:org_id, :user_id]`
- **WHEN** `run_sync(agent, %{org_id: "acme", user_id: "alice", data: 1})` is called
- **THEN** `org_id` and `user_id` SHALL be in ambient; `data` SHALL be in working
