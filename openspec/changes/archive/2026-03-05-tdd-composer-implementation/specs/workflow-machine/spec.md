## Reference Documents

Read these before implementing:

- **Design**: `docs/design/workflow/state-machine.md` — Complete Machine struct definition, all operations (new/1, current_node/1, transition/2, terminal?/1, apply_result/2), transition lookup fallback chain diagram, terminal state semantics, relationship to Jido's existing FSM
- **Design**: `docs/design/nodes/context-flow.md` — "Context in Workflows" section: scope key is the state name atom, deep merge semantics, non-map values overwrite (safe under scoping)
- **Design**: `docs/design/foundations.md` — Monoid laws (associativity, identity, closure) that Machine must preserve, Kleisli error short-circuit
- **PLAN.md**: Step 5 — Machine struct fields, transition fallback chain with wildcard priority order, apply_result scoping
- **Learnings**: `prototypes/learnings.md` — "Deep Merge Lists Overwrite" confirms scoping prevents cross-node issues. Performance: ~617,000 transitions/sec
- **Prototype**: `prototypes/test_fsm_deep_merge.exs` — 7 tests validating linear pipeline, branching, wildcards, deep merge edge cases, context growth, associativity

## ADDED Requirements

### Requirement: Machine struct holds FSM state

`Jido.Composer.Workflow.Machine` SHALL be a struct containing `status`, `nodes`, `transitions`, `terminal_states`, `context`, and `history` fields.

#### Scenario: Creating a new machine

- **WHEN** `Machine.new(opts)` is called with nodes, transitions, initial state, and optional terminal states
- **THEN** it SHALL return a `%Machine{}` with `status` set to the initial state, empty context, empty history, and default terminal states `[:done, :failed]`

#### Scenario: Custom terminal states

- **WHEN** `Machine.new(opts)` is called with `terminal_states: [:completed, :aborted]`
- **THEN** the machine SHALL use those as terminal states instead of defaults

### Requirement: Machine.transition/2 applies state transitions with fallback chain

Transition lookup SHALL follow a four-level fallback: exact match, wildcard state, wildcard outcome, global fallback.

#### Scenario: Exact transition match

- **WHEN** `Machine.transition(machine, :ok)` is called and transitions contain `{:current_state, :ok} => :next_state`
- **THEN** it SHALL return `{:ok, machine}` with `status` updated to `:next_state`

#### Scenario: Wildcard state fallback

- **WHEN** no exact match exists but `{:_, :error} => :failed` is defined
- **THEN** the transition SHALL match on the wildcard state entry

#### Scenario: Wildcard outcome fallback

- **WHEN** no exact or wildcard-state match exists but `{:current_state, :_} => :default_next` is defined
- **THEN** the transition SHALL match on the wildcard outcome entry

#### Scenario: Global fallback

- **WHEN** no other match exists but `{:_, :_} => :fallback` is defined
- **THEN** the transition SHALL match on the global fallback

#### Scenario: No transition found

- **WHEN** no matching transition exists (including wildcards)
- **THEN** it SHALL return `{:error, :no_transition}` with the current state and outcome

### Requirement: Machine detects terminal states

The machine SHALL report whether its current state is terminal.

#### Scenario: Terminal state reached

- **WHEN** the machine's current `status` is in `terminal_states`
- **THEN** `Machine.terminal?(machine)` SHALL return `true`

#### Scenario: Non-terminal state

- **WHEN** the machine's current `status` is not in `terminal_states`
- **THEN** `Machine.terminal?(machine)` SHALL return `false`

### Requirement: Machine.current_node/1 returns the node bound to current state

The machine SHALL provide the node associated with its current state.

#### Scenario: Node exists for current state

- **WHEN** `Machine.current_node(machine)` is called and the current state has a bound node
- **THEN** it SHALL return the node struct

#### Scenario: Terminal state has no node

- **WHEN** `Machine.current_node(machine)` is called on a terminal state with no bound node
- **THEN** it SHALL return `nil`

### Requirement: Machine.apply_result/3 scopes and deep merges results

Results SHALL be stored under the state name key and deep merged into the flowing context.

#### Scenario: Scoped result accumulation

- **WHEN** `Machine.apply_result(machine, :extract, %{records: [1, 2]})` is called
- **THEN** the machine's context SHALL contain `%{extract: %{records: [1, 2]}}`

#### Scenario: Multiple results accumulate without collision

- **WHEN** results from `:extract` and `:transform` are applied sequentially
- **THEN** the context SHALL contain both `%{extract: %{...}, transform: %{...}}` without data loss

#### Scenario: Deep merge within same scope

- **WHEN** a result is applied to the same state twice (e.g., re-entry)
- **THEN** map values SHALL be deep merged, non-map values SHALL be overwritten

### Requirement: Machine tracks execution history

Each transition SHALL append a history entry.

#### Scenario: History records state transitions

- **WHEN** the machine transitions through `:extract` -> `:transform` -> `:done`
- **THEN** `machine.history` SHALL contain tuples `{state, outcome, timestamp}` for each transition
