## Reference Documents

- **Design**: `native-agent-composition.md` §5 — FanOutBranch directive, strategy state, dispatch, cancellation
- **Design**: `docs/design/workflow/strategy.md` — FanOut section, branch result handler
- **Prototype**: `prototypes/test_fan_out_execution.exs` — 8 passing tests
- **Prototype**: `prototypes/test_integrated_composition.exs` — mixed FanOut test
- **Learnings**: `prototypes/learnings.md` — "FanOutNode — Pure Node Implementation", 10x speedup
- **PLAN**: `IMPLEMENTATION_PLAN.md` Phase 4

## ADDED Requirements

### Requirement: FanOutBranch directive encapsulates per-branch execution

`Jido.Composer.Directive.FanOutBranch` SHALL be a struct carrying either an `instruction` (for ActionNode) or a `spawn_agent` (for AgentNode), identified by `fan_out_id` and `branch_name`.

#### Scenario: ActionNode branch directive

- **WHEN** a FanOutNode contains an ActionNode branch named `:validate`
- **THEN** the strategy SHALL emit a `FanOutBranch` with `instruction` set and `spawn_agent` nil

#### Scenario: AgentNode branch directive

- **WHEN** a FanOutNode contains an AgentNode branch named `:analyze`
- **THEN** the strategy SHALL emit a `FanOutBranch` with `spawn_agent` set and `instruction` nil

### Requirement: Strategy tracks FanOut completion state

The Workflow strategy SHALL maintain `pending_fan_out` state tracking total branches, pending branches, completed results, and queued branches.

#### Scenario: Branch result tracked

- **WHEN** a `fan_out_branch_result` arrives for branch `:validate`
- **THEN** `:validate` SHALL be removed from `pending_branches` and its result stored in `completed_results`

#### Scenario: All branches complete triggers merge and transition

- **WHEN** all branches have completed and no branches are queued
- **THEN** the strategy SHALL merge results, apply to machine, and transition on outcome `:ok`

### Requirement: Fail-fast cancellation on branch error

When `on_error: :fail_fast` and a branch fails, the strategy SHALL emit `StopChild` directives for running agent branches.

#### Scenario: Error triggers cancel

- **WHEN** branch `:analyze` returns `{:error, reason}` with `on_error: :fail_fast`
- **THEN** cancel directives SHALL be emitted for all remaining pending branches
- **AND** the machine SHALL transition on outcome `:error`

### Requirement: Collect-partial continues on branch error

When `on_error: :collect_partial`, the strategy SHALL store branch errors and continue execution.

#### Scenario: Error stored, flow continues

- **WHEN** branch `:analyze` returns `{:error, reason}` with `on_error: :collect_partial`
- **THEN** the error SHALL be stored in `completed_results` as `{:error, reason}`
- **AND** remaining branches SHALL continue executing

### Requirement: Backpressure via max_concurrency

FanOutNode SHALL support a `max_concurrency` field limiting how many branches execute simultaneously.

#### Scenario: Only N branches dispatched initially

- **GIVEN** `max_concurrency: 2` with 5 branches
- **WHEN** the strategy dispatches the FanOutNode
- **THEN** only 2 FanOutBranch directives SHALL be emitted
- **AND** the remaining 3 SHALL be in `queued_branches`

#### Scenario: Queued branches dispatch as slots open

- **WHEN** a branch completes and `queued_branches` is non-empty
- **THEN** the next queued branch SHALL be dispatched

## MODIFIED Requirements

### Requirement: FanOutNode execution moves from inline to directive-based

The Workflow strategy SHALL no longer call `FanOutNode.run/3` inline. Instead it SHALL decompose the FanOutNode into individual `FanOutBranch` directives.

#### Scenario: Strategy emits directives instead of inline execution

- **WHEN** `dispatch_current_node` encounters a `FanOutNode`
- **THEN** it SHALL emit one `FanOutBranch` directive per branch (up to `max_concurrency`)
- **AND** SHALL NOT call `Task.async_stream` in the strategy

### Requirement: DSL run_sync handles FanOutBranch directives

The `run_directives/3` function SHALL recognize `FanOutBranch` directives and execute them locally via `Task.async_stream`.

#### Scenario: FanOutBranch execution in run_sync

- **WHEN** `run_directives/3` encounters `FanOutBranch` directives
- **THEN** it SHALL execute all branches concurrently and feed each result back through `cmd/3` as `fan_out_branch_result`

### Requirement: Child result routing disambiguates FanOut vs single child

The `workflow_child_result` handler SHALL check the tag to route FanOut branch results separately from single-child results.

#### Scenario: FanOut tag routes to branch handler

- **WHEN** `workflow_child_result` arrives with tag `{:fan_out, id, branch_name}`
- **THEN** it SHALL be routed to the FanOut branch result handler
