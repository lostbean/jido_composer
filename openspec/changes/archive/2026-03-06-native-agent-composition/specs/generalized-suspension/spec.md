## Reference Documents

- **Design**: `native-agent-composition.md` §6 — Suspension struct, Suspend directive, strategy generalization, FanOut partial completion
- **Design**: `docs/design/hitl/strategy-integration.md` — Suspend/resume signal routes, strategy state
- **Design**: `docs/design/hitl/nested-propagation.md` — Cross-boundary suspension
- **Prototype**: `prototypes/test_hitl_assumptions.exs` — 8 passing tests
- **Prototype**: `prototypes/test_integrated_composition.exs` — suspension/resume tests
- **Learnings**: `prototypes/learnings.md` — "DirectiveExec Return Types"
- **PLAN**: `IMPLEMENTATION_PLAN.md` Phase 5

## ADDED Requirements

### Requirement: Suspension struct generalizes ApprovalRequest

`Jido.Composer.Suspension` SHALL carry suspension metadata for any reason, not just HITL.

#### Scenario: Rate limit suspension

- **WHEN** `Suspension.new(id: id, reason: :rate_limit, timeout: 60_000)` is called
- **THEN** it SHALL create a Suspension with reason `:rate_limit` and timeout

#### Scenario: From ApprovalRequest (backward compat)

- **WHEN** `Suspension.from_approval_request(approval_request)` is called
- **THEN** it SHALL create a Suspension with `reason: :human_input` and `approval_request` set

#### Scenario: Supported reason types

- **THEN** the following reasons SHALL be supported: `:human_input`, `:rate_limit`, `:async_completion`, `:external_job`, `:custom`

### Requirement: Suspend directive generalizes SuspendForHuman

`Jido.Composer.Directive.Suspend` SHALL replace `SuspendForHuman` as the primary suspension directive.

#### Scenario: Suspend with suspension metadata

- **WHEN** `%Suspend{suspension: suspension}` is emitted
- **THEN** the runtime SHALL deliver notifications and optionally start timeout timers

#### Scenario: SuspendForHuman produces Suspend directive

- **WHEN** `SuspendForHuman.new(approval_request: req)` is called
- **THEN** it SHALL return a `%Suspend{}` directive wrapping `Suspension.from_approval_request(req)`

### Requirement: Any node returning :suspend triggers generalized suspension

The strategy SHALL handle `:suspend` outcome from any node type, not just HumanNode.

#### Scenario: Custom node suspends

- **WHEN** a node returns `{:ok, context, :suspend}` with `__suspension__` in context
- **THEN** the strategy SHALL extract the Suspension, set `pending_suspension`, and emit a Suspend directive

#### Scenario: HumanNode suspend (backward compat)

- **WHEN** a HumanNode returns `{:ok, context, :suspend}` with `__approval_request__` in context
- **THEN** the strategy SHALL create a Suspension via `from_approval_request/1` (same behavior as before)

## MODIFIED Requirements

### Requirement: Strategy state uses pending_suspension instead of pending_approval

Both Workflow and Orchestrator strategies SHALL replace `pending_approval` with `pending_suspension`.

#### Scenario: Generic resume with matching suspension id

- **WHEN** `suspend_resume` is received with matching `suspension_id`
- **AND** the suspension reason is not `:human_input`
- **THEN** the strategy SHALL apply resume data, clear `pending_suspension`, and transition on the provided outcome

#### Scenario: HITL resume delegates to existing handler

- **WHEN** `suspend_resume` is received for a `reason: :human_input` suspension
- **THEN** the strategy SHALL delegate to the existing HITL response handling

#### Scenario: Mismatched suspension id returns error

- **WHEN** `suspend_resume` is received with a different `suspension_id` than `pending_suspension.id`
- **THEN** the strategy SHALL return an error directive

#### Scenario: Timeout fires with configured outcome

- **WHEN** `suspend_timeout` fires for an active suspension with `timeout_outcome: :timed_out`
- **THEN** the machine SHALL transition on outcome `:timed_out`

### Requirement: Orchestrator generalizes tool call suspension

The Orchestrator strategy SHALL support non-HITL suspension for tool calls alongside the existing approval gate.

#### Scenario: Rate-limited tool call

- **WHEN** a tool call returns `{:ok, ctx, :suspend}` with `reason: :rate_limit`
- **THEN** the strategy SHALL track it in `suspended_calls` and emit a Suspend directive
