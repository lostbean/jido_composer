## ADDED Requirements

### Requirement: FanOutBranch carries a child_node and params

FanOutBranch directive SHALL contain a `child_node` field (any Node struct) and a `params` field (map). The `instruction` and `spawn_agent` fields SHALL be removed.

#### Scenario: FanOutBranch with ActionNode child

- **WHEN** a FanOutBranch is created with an ActionNode child_node and params `%{value: 1}`
- **THEN** the directive's `child_node` field contains the ActionNode struct and `params` contains the execution context

#### Scenario: FanOutBranch with AgentNode child

- **WHEN** a FanOutBranch is created with an AgentNode child_node
- **THEN** the directive's `child_node` field contains the AgentNode struct (no separate `spawn_agent` field)

#### Scenario: FanOutBranch serialization

- **WHEN** a FanOutBranch with any Node struct child is serialized via `:erlang.term_to_binary/2`
- **THEN** the serialized form contains only atoms, maps, and keywords (no closures) and round-trips successfully via `:erlang.binary_to_term/1`

### Requirement: Single execution dispatch for FanOutBranch

The DSL executor and runtime SHALL dispatch FanOutBranch execution through the Node interface: `child_node.__struct__.run(child_node, params, [])`. There SHALL NOT be multiple pattern-matched dispatch paths based on instruction shape.

#### Scenario: DSL executor dispatches ActionNode branch

- **WHEN** the DSL executor processes a FanOutBranch with an ActionNode child
- **THEN** it calls `ActionNode.run(action_node, params, [])` and returns the result

#### Scenario: DSL executor dispatches AgentNode branch

- **WHEN** the DSL executor processes a FanOutBranch with an AgentNode child
- **THEN** it calls `AgentNode.run(agent_node, params, [])` and returns the result

#### Scenario: DSL executor dispatches FanOutNode branch (nested)

- **WHEN** the DSL executor processes a FanOutBranch with a FanOutNode child
- **THEN** it calls `FanOutNode.run(fan_out_node, params, [])` and returns the result

### Requirement: FanOutNode generates node-based directives

FanOutNode.to_directive/3 SHALL produce FanOutBranch directives with `child_node` set to the branch's Node struct and `params` set to the execution context.

#### Scenario: FanOutNode with ActionNode branches

- **WHEN** FanOutNode.to_directive/3 is called with branches `[{:a, action_node}, {:b, action_node_2}]`
- **THEN** it returns two FanOutBranch directives, each with `child_node` set to the respective ActionNode

#### Scenario: FanOutNode with AgentNode branches

- **WHEN** FanOutNode.to_directive/3 is called with a branch `{:agent, agent_node}`
- **THEN** it returns a FanOutBranch with `child_node` set to the AgentNode struct

#### Scenario: FanOutNode with mixed branch types

- **WHEN** FanOutNode.to_directive/3 is called with branches containing ActionNode, AgentNode, and FanOutNode children
- **THEN** each FanOutBranch has the correct `child_node` set to the respective Node struct

### Requirement: Function branches migrate to nodes

FanOutNode branches that are currently 1-arity functions SHALL no longer be supported as bare functions. They MUST be wrapped in ActionNode or another Node type before use.

#### Scenario: Bare function branch rejected

- **WHEN** FanOutNode is created with a branch `{:calc, fn ctx -> {:ok, ctx} end}`
- **THEN** creation fails with an error indicating branches must be Node structs

#### Scenario: Function wrapped in ActionNode

- **WHEN** a user has a function branch and wraps the logic in a Jido.Action module, then uses `ActionNode.new(MyAction)` as the branch
- **THEN** the FanOutNode accepts it and generates proper FanOutBranch directives

### Requirement: Queued branches are checkpoint-safe

FanOut.State's `queued_branches` list SHALL contain only serializable data — no closures or function references. This ensures checkpoint/restore works correctly for fan-out operations with `max_concurrency` limiting.

#### Scenario: Checkpoint with queued ActionNode branches

- **WHEN** a FanOut operation has 5 branches with max_concurrency 2, and a checkpoint is taken after 2 branches are dispatched
- **THEN** the 3 queued FanOutBranch directives in FanOut.State serialize and deserialize correctly

#### Scenario: Checkpoint with queued AgentNode branches

- **WHEN** a FanOut operation has queued AgentNode branches and a checkpoint is taken
- **THEN** the queued directives round-trip through `:erlang.term_to_binary` and `:erlang.binary_to_term` without loss

#### Scenario: Restore and drain queued branches

- **WHEN** a checkpointed FanOut.State is restored and `drain_queue/1` is called
- **THEN** the drained FanOutBranch directives have valid `child_node` structs that can be dispatched via `child_node.__struct__.run/3`

### Requirement: Fan-out suspension and resume works with node-based branches

HITL (Human-in-the-Loop) suspension within fan-out branches SHALL work correctly with node-based FanOutBranch directives.

#### Scenario: HumanNode branch suspends within fan-out

- **WHEN** a FanOutNode has a HumanNode branch and that branch returns `{:ok, ctx, :suspend}`
- **THEN** the fan-out tracks it in `suspended_branches` and other branches continue execution

#### Scenario: Suspended branch resumes

- **WHEN** a suspended fan-out branch receives approval via `handle_fan_out_branch_resume`
- **THEN** the branch result is recorded in `completed_results` and the fan-out may complete

#### Scenario: All branches suspend

- **WHEN** all fan-out branches suspend (e.g., all are HumanNode)
- **THEN** FanOut.State.completion_status returns `:suspended` and a Suspend directive is emitted

### Requirement: Telemetry events preserve branch node metadata

Fan-out telemetry events SHALL include the child node type in event metadata so observability tools can distinguish branch execution types.

#### Scenario: Telemetry event for ActionNode branch

- **WHEN** a fan-out branch with an ActionNode child completes
- **THEN** the telemetry event metadata includes `node_type: :action_node` or equivalent

#### Scenario: Telemetry event for AgentNode branch

- **WHEN** a fan-out branch with an AgentNode child completes
- **THEN** the telemetry event metadata includes `node_type: :agent_node` or equivalent
