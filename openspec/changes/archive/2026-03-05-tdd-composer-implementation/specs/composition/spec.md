## Reference Documents

Read these before implementing:

- **Design**: `docs/design/composition.md` — Complete nesting patterns diagram, supported compositions table (8 combinations), communication across boundaries sequence diagram, key properties (signal-based, serializable, hierarchical, isolated), depth/recursion diagram, HITL across boundaries, comparison with Exec.Chain and Plan
- **Design**: `docs/design/nodes/context-flow.md` — "Context Across Agent Boundaries" section: context serialized into signal payload, must be plain maps (no PIDs/closures)
- **Design**: `docs/design/workflow/strategy.md` — "Execution Flow: AgentNode" for workflow containing sub-agents
- **Design**: `docs/design/orchestrator/strategy.md` — "Tool Execution" for orchestrator invoking tools that are workflows
- **Design**: `docs/design/foundations.md` — "Nesting as Functorial Embedding" — inner category mapped to single morphism in outer category
- **PLAN.md**: Step 12 — Nesting example code: ETLWorkflow inside Coordinator orchestrator
- **Learnings**: `prototypes/learnings.md` — "SpawnAgent Lifecycle" confirms parent-child communication. "on_parent_death" confirms cleanup. Performance numbers for context serialization (36 KB for 10 nodes)
- **Prototype**: `prototypes/test_agent_server_children.exs` — Full SpawnAgent lifecycle validation

## ADDED Requirements

### Requirement: Workflows can contain AgentNode states

A workflow SHALL support states bound to AgentNodes, executing sub-agents as part of the FSM pipeline.

#### Scenario: Sub-agent node in workflow

- **WHEN** a workflow state binds to an AgentNode (sync mode)
- **THEN** the strategy SHALL spawn the sub-agent, deliver context via signal, receive result via emit_to_parent, and continue the FSM

#### Scenario: Sub-agent failure triggers error transition

- **WHEN** a sub-agent returns an error result
- **THEN** the workflow SHALL treat it as outcome `:error` and follow the error transition

#### Scenario: Context flows across agent boundary

- **WHEN** a sub-agent completes successfully
- **THEN** its result SHALL be scoped under the state name and deep merged into the workflow context

### Requirement: Workflows can contain FanOutNode states

A workflow SHALL support states bound to FanOutNodes for parallel execution within a single FSM state.

#### Scenario: FanOutNode in workflow state

- **WHEN** a workflow state binds to a FanOutNode
- **THEN** the strategy SHALL invoke the FanOutNode, wait for merged result, and apply the transition

#### Scenario: FanOutNode result feeds transition

- **WHEN** the FanOutNode returns `{:ok, merged_result}`
- **THEN** the outcome SHALL be `:ok` and the merged result scoped under the state name

### Requirement: Orchestrators can invoke workflows as tools

A workflow agent SHALL appear as a single tool to an orchestrator's LLM.

#### Scenario: Workflow appears as LLM tool

- **WHEN** a workflow is registered as an orchestrator node
- **THEN** `AgentTool.to_tool/1` SHALL generate a tool description from the workflow's metadata

#### Scenario: LLM selects workflow tool

- **WHEN** the LLM returns a tool call for the workflow
- **THEN** the orchestrator SHALL spawn the workflow as a sub-agent, deliver context, and receive the completed result

#### Scenario: Workflow result as tool result

- **WHEN** the workflow completes
- **THEN** its accumulated context SHALL be formatted as a tool result and passed to the next LLM call

### Requirement: Arbitrary nesting depth

Composition SHALL support nesting to arbitrary depth without special handling.

#### Scenario: Three-level nesting

- **WHEN** an orchestrator invokes a workflow that contains an AgentNode running another workflow
- **THEN** context SHALL flow correctly through all three levels and results propagate back up

### Requirement: Composition isolation

Parent agents SHALL NOT know or depend on child agent internals.

#### Scenario: Parent does not know child strategy type

- **WHEN** a parent workflow invokes an AgentNode
- **THEN** the parent SHALL only see the child's external interface (signal in, signal out) regardless of whether the child is a Workflow, Orchestrator, or custom strategy
