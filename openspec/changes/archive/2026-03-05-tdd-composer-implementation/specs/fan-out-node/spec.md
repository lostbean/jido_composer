## Reference Documents

Read these before implementing:

- **Design**: `docs/design/nodes/README.md` — FanOutNode section: struct fields table (name, branches, merge, timeout), execution steps (4 steps), default merge strategy example, custom merge function signature, error handling, relationship to arrow combinators (fan-out `&&&`), when to use FanOutNode vs Orchestrator
- **Design**: `docs/design/workflow/strategy.md` — "Execution Flow: FanOutNode" section: from strategy perspective, FanOutNode is no different from ActionNode (single result, single transition). Parallelism fully encapsulated
- **Design**: `docs/design/foundations.md` — "Arrow Combinators: Parallel and Fan-Out" section: `fanout(f, g)(ctx) = merge(f(ctx), g(ctx))`. FanOutNode is the concrete implementation of the `&&&` combinator
- **Learnings**: `prototypes/learnings.md` — "FanOutNode — Pure Node Implementation" confirms `Task.async_stream` works correctly within `run/2`. Performance: 10x100ms branches complete in ~101ms (9.9x speedup)
- **Prototype**: `prototypes/test_fan_out_execution.exs` — 8 tests validating concurrent branches, fail-fast, timeout, scoped merge, Node wrappers, 10x parallel speedup

## ADDED Requirements

### Requirement: FanOutNode executes child nodes concurrently

`Jido.Composer.Node.FanOutNode` SHALL implement the `Node` behaviour and execute multiple child nodes in parallel, merging their results.

#### Scenario: Concurrent execution of branches

- **WHEN** `FanOutNode.run(fan_out, context, opts)` is called with 3 child nodes
- **THEN** all 3 nodes SHALL execute concurrently and their results SHALL be collected

#### Scenario: Single branch degenerates to sequential

- **WHEN** a FanOutNode contains only 1 child node
- **THEN** it SHALL execute that node and return its result normally

### Requirement: FanOutNode supports configurable merge strategies

Results from branches SHALL be merged according to a configurable strategy.

#### Scenario: Default deep_merge strategy

- **WHEN** merge strategy is `:deep_merge` (default)
- **THEN** each branch result SHALL be scoped under its branch name and deep merged into a single map

#### Scenario: Custom merge function

- **WHEN** merge strategy is a function receiving `[{branch_name, result}]`
- **THEN** the function SHALL be called with all branch results and its return value used as the merged result

### Requirement: FanOutNode handles errors

FanOutNode SHALL support configurable error handling for branch failures.

#### Scenario: Fail-fast on any branch error

- **WHEN** any branch returns `{:error, reason}` and error handling is `:fail_fast` (default)
- **THEN** FanOutNode SHALL return `{:error, reason}` immediately

#### Scenario: Collect partial results on error

- **WHEN** a branch fails and error handling is `:collect_partial`
- **THEN** FanOutNode SHALL return `{:ok, merged_partial_results}` with successful branches only

### Requirement: FanOutNode enforces timeout

All branches SHALL complete within a configurable timeout.

#### Scenario: Default timeout

- **WHEN** no timeout is specified
- **THEN** the timeout SHALL default to `30_000` milliseconds

#### Scenario: Timeout exceeded

- **WHEN** any branch does not complete within the timeout
- **THEN** FanOutNode SHALL return `{:error, :timeout}` with partial results if available

### Requirement: FanOutNode metadata

FanOutNode SHALL provide descriptive metadata.

#### Scenario: Name reflects composition

- **WHEN** `name(fan_out)` is called
- **THEN** it SHALL return a name identifying the fan-out and its branches
