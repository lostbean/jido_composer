## Reference Documents

Read these before implementing:

- **Design**: `docs/design/hitl/README.md` — Three layers overview diagram (Node → Strategy → System), design principles: humans are nodes, transport independence, isolation across nesting, graceful resource management
- **Design**: `docs/design/hitl/human-node.md` — HumanNode struct fields, run/2 contract (always returns `{:ok, ctx, :suspend}`), prompt evaluation, context filtering, ApprovalRequest construction
- **Design**: `docs/design/hitl/approval-lifecycle.md` — ApprovalRequest full field table (14 fields, who sets each), ApprovalResponse field table, request-response protocol sequence diagram
- **Design**: `docs/design/hitl/strategy-integration.md` — SuspendForHuman directive fields, signal routes for HITL, Workflow suspend/resume flow, Orchestrator approval gate: partition tool calls, mixed states (awaiting_tools_and_approval), rejection handling (synthetic tool result injection), rejection policy options (:continue_siblings, :cancel_siblings, :abort_iteration)
- **Design**: `docs/design/hitl/persistence.md` — Hybrid lifecycle diagram (live → hibernated → resumed), what gets checkpointed, ParentRef PID handling, ChildRef struct, top-down resume protocol, idempotent resume (status field + compare-and-swap), schema evolution
- **Design**: `docs/design/hitl/nested-propagation.md` — Reference scenario (OuterWorkflow → InnerOrchestrator with HITL gate), parent isolation, concurrent work during child pause, cascading checkpoint/resume, cascading cancellation, multiple HITL points
- **PLAN.md**: Steps 19-29 — Full HITL implementation order with test-first descriptions
- **Learnings**: `prototypes/learnings.md` — "DirectiveExec Return Types" — SuspendForHuman must return `{:ok, state}` (not `{:stop, ...}` which would hard-stop agent). Performance: Strategy state serialization 422 bytes
- **Prototype**: `prototypes/test_hitl_assumptions.exs` — 8 tests validating suspend/resume, rejection, timeout, idempotency, serialization, approval gate, ParentRef, ChildRef

## ADDED Requirements

### Requirement: ApprovalRequest is a serializable struct

`Jido.Composer.HITL.ApprovalRequest` SHALL be a fully serializable struct representing a pending human decision.

#### Scenario: ApprovalRequest creation

- **WHEN** an ApprovalRequest is created with id, prompt, visible_context, allowed_responses, and timeout
- **THEN** it SHALL contain all fields and be serializable to JSON

#### Scenario: ApprovalRequest has unique id

- **WHEN** an ApprovalRequest is created without an explicit id
- **THEN** it SHALL auto-generate a unique string id

### Requirement: ApprovalResponse is a serializable struct

`Jido.Composer.HITL.ApprovalResponse` SHALL represent a human's response to an approval request.

#### Scenario: ApprovalResponse validation

- **WHEN** an ApprovalResponse is created with request_id, decision, and optional data
- **THEN** the decision SHALL be validated against the original request's allowed_responses

### Requirement: HumanNode returns suspend outcome

`Jido.Composer.Node.HumanNode` SHALL implement the `Node` behaviour and always return `{:ok, context, :suspend}`.

#### Scenario: HumanNode execution produces suspend

- **WHEN** `HumanNode.run(context, opts)` is called
- **THEN** it SHALL return `{:ok, updated_context, :suspend}` with an ApprovalRequest in `context.__approval_request__`

#### Scenario: Static prompt evaluation

- **WHEN** the HumanNode is configured with `prompt: "Approve this?"` (string)
- **THEN** the ApprovalRequest prompt SHALL be `"Approve this?"`

#### Scenario: Dynamic prompt evaluation

- **WHEN** the HumanNode is configured with `prompt: fn ctx -> "Approve #{ctx.amount}?" end`
- **THEN** the ApprovalRequest prompt SHALL evaluate the function against the context

#### Scenario: Context filtering

- **WHEN** the HumanNode is configured with `visible_keys: [:amount, :description]`
- **THEN** the ApprovalRequest `visible_context` SHALL only include those keys from the context

### Requirement: Workflow strategy handles suspend outcome

The workflow strategy SHALL recognize `:suspend` as a reserved outcome that pauses execution.

#### Scenario: Suspend pauses workflow

- **WHEN** a node returns `{:ok, context, :suspend}`
- **THEN** the strategy SHALL set status to `:waiting`, store the pending ApprovalRequest, and emit a `SuspendForHuman` directive

#### Scenario: Resume signal continues workflow

- **WHEN** a `composer.hitl.response` signal arrives with a valid ApprovalResponse
- **THEN** the strategy SHALL validate the response, merge it into context, use the decision as outcome for transition, and continue execution

#### Scenario: Timeout fires on pending approval

- **WHEN** a HumanNode has a timeout configured and it expires
- **THEN** the strategy SHALL use the `timeout_outcome` atom for transition lookup

### Requirement: Orchestrator strategy supports approval gates

The orchestrator SHALL support per-tool approval requirements that gate execution.

#### Scenario: Gated tool call requires approval

- **WHEN** the LLM requests a tool call for a node with `requires_approval: true`
- **THEN** the strategy SHALL hold the call at the gate and emit a `SuspendForHuman` directive

#### Scenario: Ungated tools execute while gated tools wait

- **WHEN** the LLM returns mixed tool calls (some gated, some not)
- **THEN** ungated tools SHALL execute immediately while gated tools await approval

#### Scenario: Rejection injects synthetic result

- **WHEN** a gated tool call is rejected by the human
- **THEN** the strategy SHALL inject a synthetic rejection message as the tool result and continue the LLM loop

### Requirement: HITL persistence supports checkpoint and resume

The strategy SHALL support checkpointing its state for long-pause HITL scenarios.

#### Scenario: Checkpoint serializes strategy state

- **WHEN** the SuspendForHuman directive has `hibernate: true`
- **THEN** the runtime SHALL checkpoint the full agent state (including strategy state with pending ApprovalRequest) and stop the process

#### Scenario: Resume from checkpoint

- **WHEN** a resume signal arrives for a hibernated agent
- **THEN** the runtime SHALL thaw the agent from checkpoint and deliver the ApprovalResponse signal

#### Scenario: Idempotent resume

- **WHEN** a resume signal arrives for an already-resumed agent
- **THEN** the operation SHALL be idempotent (no duplicate processing)

### Requirement: Nested HITL propagates correctly

HITL pauses in nested agents SHALL propagate correctly through composition boundaries.

#### Scenario: Child suspend does not affect parent status

- **WHEN** a child agent suspends for HITL
- **THEN** the parent agent SHALL remain in `:waiting` status (waiting for child result) — it does not know the child is paused

#### Scenario: Cascading checkpoint

- **WHEN** both parent and child need checkpointing
- **THEN** the child SHALL checkpoint first, then the parent SHALL checkpoint with ChildRef pointing to the child's checkpoint

#### Scenario: Top-down resume

- **WHEN** resuming a nested HITL scenario
- **THEN** the parent SHALL be thawed first, re-spawn the child from checkpoint, and deliver the approval response to the innermost suspended agent
