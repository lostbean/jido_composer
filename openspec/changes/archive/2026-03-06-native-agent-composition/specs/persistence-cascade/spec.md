## Reference Documents

- **Design**: `native-agent-composition.md` §7 — Three-tier management, checkpoint structure, cascading protocol, top-down resume, idempotency, schema evolution
- **Design**: `docs/design/hitl/persistence.md` — Checkpoint format, ChildRef, hibernate/thaw
- **Prototype**: `prototypes/test_hitl_assumptions.exs` — serialization and idempotency tests
- **Learnings**: `prototypes/learnings.md` — "**parent**.pid not stripped by Persist"
- **PLAN**: `IMPLEMENTATION_PLAN.md` Phase 6

## ADDED Requirements

### Requirement: Checkpoint preparation strips non-serializable closures

`Jido.Composer.Checkpoint.prepare_for_checkpoint/1` SHALL strip closures from strategy state and produce a fully serializable representation.

#### Scenario: Approval policy closure stripped

- **WHEN** `prepare_for_checkpoint(strat)` is called with `approval_policy: fn -> ... end`
- **THEN** the result SHALL have `approval_policy: nil`

#### Scenario: Serializable fields preserved

- **WHEN** `prepare_for_checkpoint(strat)` is called
- **THEN** MFA tuples, atoms, maps, and MapSets SHALL be preserved unchanged

### Requirement: Runtime config reattachment from strategy opts

`Checkpoint.reattach_runtime_config/2` SHALL restore closures from the module's `strategy_opts`.

#### Scenario: Round-trip preserves functionality

- **WHEN** a checkpoint is prepared, stored, restored, and reattached
- **THEN** the strategy SHALL function identically to before checkpointing

### Requirement: Checkpoint schema v2

Composer checkpoints SHALL use `checkpoint_schema: :composer_v2` with an extended format including `pending_suspension` and `children_checkpoints`.

#### Scenario: Schema version field

- **WHEN** a checkpoint is created
- **THEN** it SHALL include `checkpoint_schema: :composer_v2`

#### Scenario: Migration from v1

- **WHEN** a `:composer_v1` checkpoint is loaded
- **THEN** it SHALL be automatically migrated to v2 format (adding default nil for new fields)

### Requirement: Resume module provides thaw-and-resume API

`Jido.Composer.Resume.resume/5` SHALL find or thaw an agent and deliver a resume signal.

#### Scenario: Live agent receives resume directly

- **WHEN** the target agent is running in an AgentServer
- **THEN** `resume/5` SHALL deliver the signal directly via GenServer.call

#### Scenario: Checkpointed agent thawed and resumed

- **WHEN** the target agent is not running but has a checkpoint
- **THEN** `resume/5` SHALL thaw from storage, start AgentServer, and deliver resume signal

#### Scenario: Already-resumed checkpoint rejected

- **WHEN** `resume/5` is called for a checkpoint with `status: :resumed`
- **THEN** it SHALL return `{:error, :already_resumed}`

#### Scenario: Unknown agent returns error

- **WHEN** `resume/5` is called for a non-existent agent
- **THEN** it SHALL return `{:error, :agent_not_found}`

## MODIFIED Requirements

### Requirement: ChildRef moves to top-level Composer namespace

`Jido.Composer.ChildRef` SHALL be the canonical location, with an alias in `Jido.Composer.HITL.ChildRef` for backward compatibility.

#### Scenario: ChildRef includes suspension_id

- **WHEN** a ChildRef is created for a suspended child
- **THEN** it SHALL include `suspension_id` linking to the active Suspension

#### Scenario: ChildRef status transitions

- **THEN** ChildRef status SHALL support: `:running` → `:paused` → `:completed` and `:running` → `:failed`

### Requirement: Cascading checkpoint protocol

When a nested agent suspends, checkpoint cascade SHALL proceed inside-out.

#### Scenario: Child checkpoints before parent

- **WHEN** an inner agent's `hibernate_after` fires
- **THEN** the inner agent SHALL checkpoint first
- **AND** signal `composer.child.hibernated` to parent
- **AND** parent SHALL update ChildRef with `status: :paused` and `checkpoint_key`

#### Scenario: Parent checkpoints independently

- **WHEN** the parent's own `hibernate_after` fires
- **THEN** the parent SHALL checkpoint with full `children_checkpoints` map

### Requirement: Top-down resume protocol

Restoration SHALL proceed top-down: outermost agent first, then children.

#### Scenario: Parent thaws and respawns children

- **WHEN** a parent agent is thawed from checkpoint
- **THEN** the strategy SHALL detect `ChildRef` entries with `status: :paused`
- **AND** thaw each child from its `checkpoint_key`
- **AND** spawn each child with fresh PIDs

### Requirement: Fan-out partial completion survives checkpoint

The `pending_fan_out` state (completed + suspended branches) SHALL be fully serializable.

#### Scenario: Checkpoint during partial fan-out

- **WHEN** a checkpoint occurs with 2/4 FanOut branches completed and 1 suspended
- **THEN** the restored state SHALL know which branches completed, which are suspended, and which are queued
