## Reference Documents

Read these before implementing:

- **Design**: `docs/design/nodes/README.md` — Node contract, callback table, all 4 node types, design decisions (why structs, why separate from Jido.Action)
- **Design**: `docs/design/nodes/context-flow.md` — Scoped accumulation model, deep merge semantics, non-map value behaviour, mathematical foundation (endomorphism monoid)
- **Design**: `docs/design/foundations.md` — Category theory underpinnings: Ctx category, Kleisli arrows, outcome coproducts. Laws that must hold (identity, associativity, left zero)
- **PLAN.md**: Step 2 — Node behaviour implementation details with code examples
- **Learnings**: `prototypes/learnings.md` — "Module Type Detection" section confirms `function_exported?(mod, :run, 2)` distinguishes Action from Agent

## ADDED Requirements

### Requirement: Node behaviour defines universal callback contract

The `Jido.Composer.Node` module SHALL define a behaviour with four callbacks: `run/2`, `name/0`, `description/0`, and `schema/0`.

#### Scenario: Module implementing Node exports required callbacks

- **WHEN** a module declares `@behaviour Jido.Composer.Node`
- **THEN** the compiler SHALL require implementations of `run/2`, `name/0`, `description/0`, and `schema/0`

### Requirement: Node run/2 returns outcome-tagged results

The `run/2` callback SHALL accept `(context :: map(), opts :: keyword())` and return one of three result types.

#### Scenario: Successful execution with implicit ok outcome

- **WHEN** `run/2` returns `{:ok, context_map}`
- **THEN** the result SHALL be treated as outcome `:ok` with the returned context

#### Scenario: Successful execution with explicit outcome

- **WHEN** `run/2` returns `{:ok, context_map, :some_outcome}`
- **THEN** the result SHALL carry the explicit outcome atom for FSM transition lookup

#### Scenario: Failed execution

- **WHEN** `run/2` returns `{:error, reason}`
- **THEN** the result SHALL be treated as outcome `:error` with the given reason

### Requirement: Node metadata callbacks return descriptive information

The `name/0`, `description/0`, and `schema/0` callbacks SHALL provide metadata for tool integration and introspection.

#### Scenario: Name returns string identifier

- **WHEN** `name/0` is called on a Node implementation
- **THEN** it SHALL return a `String.t()` identifying the node

#### Scenario: Description returns human-readable text

- **WHEN** `description/0` is called on a Node implementation
- **THEN** it SHALL return a `String.t()` describing the node's purpose

#### Scenario: Schema returns validation specification or nil

- **WHEN** `schema/0` is called on a Node implementation
- **THEN** it SHALL return a `keyword()` schema or `nil` if no schema applies
