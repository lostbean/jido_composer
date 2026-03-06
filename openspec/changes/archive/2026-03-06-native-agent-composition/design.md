## Architecture Overview

Six interlocking changes make agents native composition blocks. Each preserves
the existing categorical structure (endomorphism monoid over context maps) while
adding capabilities.

### Design Documents

| Document                                   | Covers                                                       |
| ------------------------------------------ | ------------------------------------------------------------ |
| `native-agent-composition.md` (root)       | Full proposal with code, friction points, feasibility matrix |
| `docs/design/nodes/README.md`              | Node behaviour contract, AgentNode modes                     |
| `docs/design/nodes/typed-io.md`            | NodeIO envelope, type adaptation                             |
| `docs/design/nodes/context-flow.md`        | Context accumulation, scoping, context layers                |
| `docs/design/workflow/strategy.md`         | Workflow strategy lifecycle, FanOut directives               |
| `docs/design/hitl/strategy-integration.md` | Suspend/resume in both strategies                            |
| `docs/design/hitl/nested-propagation.md`   | HITL across composition boundaries                           |
| `docs/design/hitl/persistence.md`          | Checkpoint/thaw, three-tier resource management              |

### Prototype Validation

All designs validated against real Jido primitives and Claude API (commit
b2baa01). See `prototypes/learnings.md` for full results. Zero design changes
required after prototyping.

## Key Design Decisions

### Dual-Path Execution (§2.2)

`AgentNode.run/3` (sync direct call) and SpawnAgent directive (process
lifecycle) coexist. FanOutNode branches and `run_sync` use the direct path.
AgentServer runtime uses the directive path. Same pattern as ActionNode's
`run/3` vs `RunInstruction`.

### NodeIO as Natural Transformation (§3.2)

`NodeIO.to_map/1` is a natural transformation from typed output back to the
monoidal map structure. Adaptation happens at a single point:
`Machine.apply_result/2`. Nodes stay simple (`map -> map`).

### Context Layers as Reader Monad (§4.2)

Three layers: ambient (Reader environment, read-only), working (existing
endomorphism monoid), fork functions (natural transformation at agent
boundaries). Nodes receive `to_flat_map/1` — no Node behaviour change.

### Directive-Based FanOut (§5.2)

FanOutNode becomes a pure data descriptor. Strategy emits `FanOutBranch`
directives (one per branch). Runtime executes them concurrently. Results flow
back via `fan_out_branch_result` command. Supports backpressure via
`max_concurrency`.

### Generalized Suspension (§6.2)

`Suspension` struct generalizes `ApprovalRequest`. `Suspend` directive
generalizes `SuspendForHuman`. Existing HITL becomes `reason: :human_input`.
New reasons: `:rate_limit`, `:async_completion`, `:external_job`, `:custom`.

### Persistence Cascade (§7.5)

Inside-out checkpoint (child first, parent independently). Top-down resume
(parent thawed first, re-spawns children from checkpoints). Idempotent via
checkpoint status field (`:hibernated` → `:resuming` → `:resumed`).

## Dependency Graph

```
Phase 1 (AgentNode.run/3) ──┬──→ Phase 2 (NodeIO) ──→ Phase 3 (Context)
                             │
                             └──→ Phase 4 (FanOut) ──→ Phase 5 (Suspension) ──→ Phase 6 (Persistence)
```

## New Files

| File                                            | Purpose                             |
| ----------------------------------------------- | ----------------------------------- |
| `lib/jido/composer/node_io.ex`                  | Typed output envelope               |
| `lib/jido/composer/context.ex`                  | Layered context struct              |
| `lib/jido/composer/suspension.ex`               | Generalized suspension metadata     |
| `lib/jido/composer/directive/suspend.ex`        | Generalized suspend directive       |
| `lib/jido/composer/directive/fan_out_branch.ex` | Per-branch fan-out directive        |
| `lib/jido/composer/checkpoint.ex`               | Checkpoint preparation and restore  |
| `lib/jido/composer/resume.ex`                   | External-facing thaw-and-resume API |

## Modified Files

| File                                               | Changes                                       |
| -------------------------------------------------- | --------------------------------------------- |
| `lib/jido/composer/node/agent_node.ex`             | Implement sync `run/3`                        |
| `lib/jido/composer/node/fan_out_node.ex`           | `max_concurrency`, NodeIO merge               |
| `lib/jido/composer/node.ex`                        | Optional type callbacks                       |
| `lib/jido/composer/workflow/machine.ex`            | Context.t(), resolve_result                   |
| `lib/jido/composer/workflow/strategy.ex`           | FanOut directives, suspension, context layers |
| `lib/jido/composer/workflow/dsl.ex`                | SpawnAgent/FanOutBranch handlers, DSL options |
| `lib/jido/composer/orchestrator/strategy.ex`       | NodeIO wrap, context layers, suspension       |
| `lib/jido/composer/orchestrator/dsl.ex`            | SpawnAgent handler, DSL options               |
| `lib/jido/composer/orchestrator/agent_tool.ex`     | NodeIO unwrap for LLM                         |
| `lib/jido/composer/directive/suspend_for_human.ex` | Wrapper around Suspend                        |
| `lib/jido/composer/hitl/child_ref.ex`              | Move to Composer namespace, add suspension_id |

## Backward Compatibility

All changes are additive or internal. Existing tests pass after each phase:

- Bare `map()` contexts auto-wrap into `Context.t()` (Phase 3)
- `SuspendForHuman` becomes a convenience wrapper, same API (Phase 5)
- Checkpoint v1 migrated to v2 automatically (Phase 6)
- Node behaviour gains optional callbacks only (Phase 2)
