## ADDED Requirements

### Requirement: MapNode accepts any Node struct

MapNode SHALL accept any struct implementing the `Jido.Composer.Node` behaviour via the `:node` option. Bare action modules SHALL be auto-wrapped in `ActionNode`.

#### Scenario: MapNode with bare action module

- **WHEN** MapNode.new is called with `node: DoubleValueAction` (a Jido.Action module)
- **THEN** the MapNode is created with `node` field set to `%ActionNode{action_module: DoubleValueAction}`

#### Scenario: MapNode with ActionNode struct

- **WHEN** MapNode.new is called with `node: %ActionNode{action_module: DoubleValueAction}`
- **THEN** the MapNode is created with the ActionNode struct stored directly

#### Scenario: MapNode with FanOutNode struct

- **WHEN** MapNode.new is called with `node: fan_out_node` (a FanOutNode struct)
- **THEN** the MapNode is created with the FanOutNode stored as the child node

#### Scenario: MapNode with AgentNode struct

- **WHEN** MapNode.new is called with `node: %AgentNode{agent_module: MyAgent}`
- **THEN** the MapNode is created with the AgentNode stored as the child node

#### Scenario: MapNode with HumanNode struct

- **WHEN** MapNode.new is called with `node: human_node` (a HumanNode struct)
- **THEN** the MapNode is created successfully, enabling per-element human approval

#### Scenario: MapNode rejects invalid values

- **WHEN** MapNode.new is called with `node: "not_a_module"` or `node: Enum`
- **THEN** creation fails with an error indicating the value must be a Node struct or Action module

### Requirement: Backward compatibility via :action option

MapNode SHALL accept the `:action` keyword as a deprecated alias for `:node`. The `:node` option takes precedence when both are provided.

#### Scenario: Backward compat with :action

- **WHEN** MapNode.new is called with `action: DoubleValueAction` (no `:node` key)
- **THEN** the MapNode is created with `node` field set to `%ActionNode{action_module: DoubleValueAction}`

#### Scenario: :node takes precedence

- **WHEN** MapNode.new is called with both `node: AddAction` and `action: DoubleAction`
- **THEN** the MapNode's `node` field is `%ActionNode{action_module: AddAction}`

### Requirement: MapNode runs child node per element

MapNode.run/3 SHALL invoke the child node's `run/3` callback for each element in the collection, passing element data as params.

#### Scenario: Map ActionNode over list of maps

- **WHEN** MapNode runs with child ActionNode wrapping DoubleValueAction and context `%{items: [%{value: 1}, %{value: 2}]}`
- **THEN** results are `%{results: [%{doubled: 2}, %{doubled: 4}]}` in order

#### Scenario: Map FanOutNode over list

- **WHEN** MapNode runs with a FanOutNode child that has two branches (double, add_ten) and context `%{items: [%{value: 5}]}`
- **THEN** results are `%{results: [%{double: %{doubled: 10}, add: %{result: 15}}]}`

#### Scenario: Map AgentNode over list

- **WHEN** MapNode runs with an AgentNode child over a list of contexts
- **THEN** the agent is invoked per element and results are collected in order

#### Scenario: Empty collection

- **WHEN** MapNode runs with an empty collection
- **THEN** results are `%{results: []}` regardless of child node type

### Requirement: MapNode generates node-based FanOutBranch directives

MapNode.to_directive/3 SHALL produce FanOutBranch directives with `child_node` set to the MapNode's child node and `params` set to the per-element execution context.

#### Scenario: Directives for ActionNode child

- **WHEN** MapNode.to_directive/3 is called with an ActionNode child and 3 items
- **THEN** it returns 3 FanOutBranch directives, each with `child_node` set to the ActionNode and `params` containing the merged element data

#### Scenario: Directives for FanOutNode child

- **WHEN** MapNode.to_directive/3 is called with a FanOutNode child and 2 items
- **THEN** it returns 2 FanOutBranch directives, each with `child_node` set to the FanOutNode

#### Scenario: Directives with max_concurrency

- **WHEN** MapNode.to_directive/3 is called with 5 items and max_concurrency 2
- **THEN** 2 FanOutBranch directives are dispatched and 3 are queued in FanOut.State

### Requirement: MapNode with node child supports checkpoint/restore

A MapNode with any Node struct child SHALL be fully checkpoint-safe. The MapNode struct and all generated FanOutBranch directives SHALL serialize and deserialize correctly.

#### Scenario: Checkpoint MapNode with ActionNode child

- **WHEN** a workflow with MapNode (ActionNode child) is checkpointed mid-execution
- **THEN** the restored MapNode has the same ActionNode child and produces identical behavior

#### Scenario: Checkpoint MapNode with FanOutNode child

- **WHEN** a workflow with MapNode (FanOutNode child) is checkpointed
- **THEN** the restored MapNode has the same FanOutNode child with all its branches intact

#### Scenario: Checkpoint with queued MapNode branches

- **WHEN** a MapNode with max_concurrency has queued branches and a checkpoint occurs
- **THEN** queued branches round-trip through serialization and can be drained and dispatched after restore

### Requirement: MapNode with HumanNode child supports suspension

When MapNode's child is a HumanNode, each element in the collection SHALL be processed through the human approval gate independently.

#### Scenario: Per-element suspension

- **WHEN** MapNode maps a HumanNode over 3 items
- **THEN** each item generates a separate suspension with its own approval request

#### Scenario: Partial approval

- **WHEN** 2 of 3 MapNode HumanNode branches are approved and 1 remains suspended
- **THEN** FanOut.State tracks 2 completed and 1 suspended, with completion_status `:suspended`

#### Scenario: All approved

- **WHEN** all MapNode HumanNode branches receive approval
- **THEN** results are merged as an ordered list and the workflow transitions

### Requirement: MapNode composition in workflows

MapNode with any Node child SHALL work correctly as a workflow state, participating in FSM transitions, context scoping, and result merging.

#### Scenario: MapNode in multi-step workflow

- **WHEN** a workflow has states `generate → process → aggregate` where `process` is a MapNode with a FanOutNode child
- **THEN** the generate output feeds into MapNode, MapNode results are scoped under `:process`, and aggregate receives the full context

#### Scenario: MapNode with error propagation

- **WHEN** a MapNode's child node fails for one element and on_error is :fail_fast
- **THEN** the workflow transitions to :error with the element failure reason

#### Scenario: MapNode with collect_partial

- **WHEN** a MapNode's child node fails for one element and on_error is :collect_partial
- **THEN** the results list includes `{:error, reason}` for the failed element and valid results for others
