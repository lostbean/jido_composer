# Persistence

When a flow [suspends](README.md#generalized-suspension) for any reason — human
input, rate limits, async completion, external jobs — the pause may last
milliseconds or months. This document describes how agent state is preserved
across pauses and how flows resume after process termination.

## Resource Management Tiers

The runtime has two effective persistence tiers plus a forward-compatible
hibernate intent flag.

| Tier                 | Trigger                                    | Process alive? | Memory                            | Resume Latency |
| -------------------- | ------------------------------------------ | -------------- | --------------------------------- | -------------- |
| **Live wait**        | Suspension starts                          | Yes            | Full agent struct                 | Instant        |
| **Hibernate intent** | `Suspend.hibernate` (`true` or `%{after}`) | Yes            | Unchanged (current runtime no-op) | Instant        |
| **Full checkpoint**  | Suspension timeout >= `hibernate_after`    | No (stopped)   | Zero (on disk)                    | Thaw + start   |

`Suspend.hibernate` (`false`, `true`, `%{after: ms}`) is currently intent-only
in AgentServer integration; durable memory reduction is performed by
`CheckpointAndStop` when suspension timeout is `>= hibernate_after`.

### CheckpointAndStop Directive

At runtime, the `DirectiveExec` protocol implementation:

1. Resolves storage from the directive or the agent's lifecycle configuration
2. Persists the checkpoint via `Jido.Persist.hibernate/2`
3. Notifies the parent by sending a `"composer.child.hibernated"` signal
4. Returns a stop tuple to terminate the process

Directive fields:

| Field             | Type                        | Purpose                                                                            |
| ----------------- | --------------------------- | ---------------------------------------------------------------------------------- |
| `suspension`      | `Suspension.t()` (required) | The active suspension that triggered checkpointing                                 |
| `storage_config`  | `map()` \| nil              | Optional override for storage backend                                              |
| `checkpoint_data` | `map()` \| nil              | Reserved field for storage-specific metadata (currently not read by DirectiveExec) |

### DirectiveExec Protocol

Both `Suspend` and `CheckpointAndStop` implement
`Jido.AgentServer.DirectiveExec`, allowing composer-specific directives without
changing jido core (`@fallback_to_any true` keeps unknown directives safe).

| Directive             | Behaviour                                                                                                                                   |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| **Suspend**           | `hibernate: false` is a no-op. `hibernate: true` or `%{after: ms}` logs intent. Primary resource management uses CheckpointAndStop instead. |
| **CheckpointAndStop** | Persists checkpoint, notifies parent via signal, stops the process.                                                                         |

## What Gets Checkpointed

The entire agent state — including strategy state under `__strategy__` — is
persisted via `Jido.Persist.hibernate/2`. The checkpoint captures the logical
state of the computation at the moment of suspension.

| Data                                        | Location                           | Serializable?                                                                                                             |
| ------------------------------------------- | ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| Machine status, context, history            | `__strategy__.machine`             | Yes (atoms, maps, timestamps)                                                                                             |
| Orchestrator conversation, tools, iteration | `__strategy__.*`                   | Yes (LLM module must ensure conversation state is serializable)                                                           |
| Pending Suspension                          | `__strategy__.pending_suspension`  | Yes (no PIDs, no closures)                                                                                                |
| FanOut state (completed + suspended)        | `__strategy__.fan_out`             | Yes (`FanOut.State` struct — results, branch names, Suspension structs, queued FanOutBranch directives with Node structs) |
| Child references and phases                 | `__strategy__.children`            | Yes (`Children` struct with `refs` and `phases` maps)                                                                     |
| Fork functions                              | `Context.fork_fns`                 | Yes (MFA tuples by design)                                                                                                |
| Approval policy (closure)                   | Orchestrator state                 | **No** — stripped on checkpoint, reattached from DSL on restore                                                           |
| Execution thread                            | Stored separately via Thread       | Yes (append-only log)                                                                                                     |
| Gated tool calls                            | `__strategy__.approval_gate`       | Yes (`ApprovalGate` struct — gated calls + approval requests)                                                             |
| Suspended tool calls                        | `__strategy__.suspended_calls`     | Yes (suspension + tool call data)                                                                                         |
| Orchestrator status                         | `__strategy__.status`              | Yes (atom — includes `:awaiting_tools_and_approval` for mixed states)                                                     |
| Child process PIDs                          | `__parent__`, AgentServer children | **No** — replaced by ChildRef                                                                                             |

## ParentRef PID Handling

The `__parent__` field in child agent state contains a
Jido.AgentServer.ParentRef struct with a `pid` field that is not serializable.
The `emit_to_parent/3` helper requires this PID to function. During
checkpointing, the `pid` field must be stripped (set to `nil`). On resume, the
parent re-spawns the child via `SpawnAgent`, which re-populates `__parent__`
with a fresh `ParentRef` pointing to the new parent PID. The `id`, `tag`, and
`meta` fields in `ParentRef` ARE serializable and are preserved across
checkpoint/restore.

## ChildRef: Serializable Child References

The strategy layer never stores raw PIDs. When checkpointing, process-level
references are replaced with serializable `ChildRef` structs. ChildRef is a
top-level Composer concept (not HITL-specific) since any suspension reason
requires serializable child tracking.

| Field            | Type                                     | Purpose                                                               |
| ---------------- | ---------------------------------------- | --------------------------------------------------------------------- |
| `agent_module`   | `module()`                               | The child's agent module (for re-spawning)                            |
| `agent_id`       | `String.t()`                             | The child's unique ID                                                 |
| `tag`            | `term()`                                 | The tag used for parent-child tracking                                |
| `checkpoint_key` | `term()`                                 | Storage key for the child's own checkpoint                            |
| `suspension_id`  | `String.t()` \| nil                      | Links to the Suspension that caused this child to pause               |
| `status`         | atom                                     | `:running` \| `:paused` \| `:hibernated` \| `:completed` \| `:failed` |
| `phase`          | `:spawning` \| `:awaiting_result` \| nil | Tracks child communication lifecycle for replay on resume             |

On resume, the strategy emits a SpawnAgent directive with the `checkpoint_key`,
telling the runtime to restore the child from its checkpoint rather than
creating a fresh agent.

## Checkpoint Structure

A Composer checkpoint extends the base `Jido.Persist` format:

| Field                         | Source       | Purpose                                                                             |
| ----------------------------- | ------------ | ----------------------------------------------------------------------------------- |
| `version`                     | Jido.Persist | Schema version for migration (current: 1)                                           |
| `checkpoint_schema`           | Composer     | `:composer_v1`                                                                      |
| `agent_module`                | Jido.Persist | The agent's module                                                                  |
| `id`                          | Jido.Persist | The agent's unique ID                                                               |
| `status`                      | Storage/CAS  | Lifecycle state used during resume CAS (`:hibernated` -> `:resuming` -> `:resumed`) |
| `state`                       | Jido.Persist | Full `agent.state` including `__strategy__`                                         |
| `thread`                      | Jido.Persist | Thread pointer `{id, rev}`                                                          |
| `state.__strategy__.children` | Composer     | Child refs/phases (`Children` struct or map fallback) used for replay               |

The strategy state within the checkpoint includes `pending_suspension` (the
active Suspension struct, if any) and `fan_out` (a `FanOut.State` struct with
completed + suspended branch state for in-progress fan-outs). Both are fully
serializable.

## Serialization Format

Checkpoints use Erlang term serialization (`:erlang.term_to_binary/2` with
`:compressed`). This is the format already used by `Jido.Storage.File` and
preserves atoms, module references, and nested data structures natively.

JSON and MsgPack exports are possible, but checkpoint persistence is optimized
around Erlang term serialization to preserve atoms/modules and avoid lossy
type conversion.

## Cascading Checkpoint Protocol

Nested checkpointing is inside-out:

1. Child suspension crosses `hibernate_after`.
2. Child persists checkpoint and emits `composer.child.hibernated`.
3. Parent marks child `ChildRef` as `:paused` (with checkpoint key).
4. Parent checkpoints only if its own threshold also fires.

## Top-Down Resume Protocol

Resume is top-down:

1. Thaw and start the outermost agent.
2. Re-spawn paused children from their `checkpoint_key`.
3. Children get fresh PIDs and fresh `__parent__` refs.
4. Deliver resume signal to the innermost suspended agent.
5. Results propagate through normal `emit_to_parent`.

### Strategy Init Restoration

When an AgentServer starts with a thawed agent, the strategy's `init/2`
detects existing strategy state (by checking that the module matches and the
status is not `:idle`) and rebuilds only runtime-derived fields — nodes, tools,
name-to-atom mappings, closures — from `strategy_opts`. The checkpointed state
(conversation, pending suspension, child refs, status) is preserved. Without
this detection, starting an AgentServer with a restored agent would obliterate
the checkpoint by reinitializing strategy state to defaults.

## Idempotent Resume

To prevent duplicate resumption, checkpoints carry a `status` field:

| Status        | Meaning                  | Transition                     |
| ------------- | ------------------------ | ------------------------------ |
| `:hibernated` | Available for resume     | -> `:resuming` on thaw         |
| `:resuming`   | Currently being restored | -> `:resumed` on completion    |
| `:resumed`    | Already restored         | Reject further resume attempts |

The storage layer provides an atomic compare-and-swap for status transitions.
If a resume attempt finds the checkpoint already in `:resuming` or `:resumed`
state, it returns `{:error, :already_resumed}`.

As a secondary defence, the Thread's monotonic revision counter prevents stale
replays: if a resumed agent has appended new Thread entries, a second resume
attempt finds a revision mismatch.

## Schema Evolution

Code may change between suspension and resumption. The checkpoint's `version`
field enables migration:

| Scenario                           | Handling                                                   |
| ---------------------------------- | ---------------------------------------------------------- |
| New fields added to strategy state | Default values applied during restore                      |
| Fields removed                     | Ignored during restore                                     |
| Transition table changed           | Agent module's `restore/2` callback maps old states to new |
| Module renamed or removed          | Restore fails with clear error; requires manual migration  |

Agent modules implement `checkpoint/2` and `restore/2` callbacks (from
`Jido.Persist`) for custom serialization and version migration logic.

## Handling In-Flight Operations

At checkpoint time, in-flight operations are restored from persisted state:

- Pending `RunInstruction`/tool work is replayed by strategy callbacks.
- In-flight HTTP/signals are not durable and are re-issued when needed.
- Child replay is phase-driven: `:spawning` re-emits `SpawnAgent`,
  `:awaiting_result` keeps waiting.

### Replay Directives

`Checkpoint.replay_directives/1` reconstructs the directives needed to resume
in-flight operations from checkpoint state. It combines child phase replays
with orchestrator operation replays into a single directive list.

**Workflow replay** re-spawns children based on their `children.phases` map
(inside the `Children` struct): `:spawning` entries produce `SpawnAgent`
directives. For backward compatibility, if `phases` is empty, the function
falls back to inspecting each `ChildRef.phase` field.

**Strategy-specific replay** delegates to the strategy module's `replay_directives_from_state/1`
callback via `function_exported?/3` (see "Strategy Checkpoint Protocol" in `Checkpoint` moduledoc).
This keeps replay logic co-located with the strategy that owns the state shape.
For `Orchestrator.Strategy`, it inspects the strategy status:

| Status                           | Replay Behaviour                                                             |
| -------------------------------- | ---------------------------------------------------------------------------- |
| `:awaiting_llm`                  | Re-emit the LLM call from conversation state                                 |
| `:awaiting_tool`                 | Re-dispatch pending tool calls (legacy status retained for compatibility)    |
| `:awaiting_tools`                | Re-dispatch all pending tool calls                                           |
| `:awaiting_tools_and_approval`   | Re-dispatch pending tool calls (gated calls await re-approval)               |
| `:awaiting_tools_and_suspension` | Re-dispatch pending tool calls; suspended calls continue through resume flow |

`Resume.resume/4` automatically prepends replay directives when it detects
`checkpoint_status` in strategy state, ensuring in-flight operations are
re-established without manual intervention.

## External Timeout Management

`Schedule` directives do not survive process death. For long-lived suspensions
(any reason, not just HITL), timeouts must be managed externally:

1. The Suspension struct includes `timeout` and `created_at`
2. An external scheduler (cron, database trigger, separate process) checks for
   expired suspensions
3. On expiry: if the agent is alive, deliver the timeout signal directly; if
   hibernated, thaw and deliver
4. If the agent's checkpoint no longer exists, mark the suspension as expired

This places timeout management outside jido_composer, which is appropriate
since the library is transport-agnostic and does not mandate a specific
scheduling infrastructure.

## Targeted Resume

Resuming a specific suspended agent in an arbitrarily deep tree requires
addressing:

1. Look up the agent by module + ID (via registry or storage)
2. If alive, deliver the resume signal directly
3. If checkpointed, thaw from storage, start in AgentServer, then deliver
4. The Suspension's `id` field ensures the correct suspension is matched

The parent does not need to be involved in targeted resume — the resume signal
goes directly to the suspended agent. Results propagate upward through the
normal `emit_to_parent` mechanism.

## Closure Stripping

Some strategy state fields contain closures that cannot be serialized (e.g.,
`approval_policy` inside the `ApprovalGate` struct in the Orchestrator). On
checkpoint, top-level closures are stripped (set to nil). On restore, they are
reattached from the agent module's DSL configuration (`strategy_opts`) —
the strategy's `restore_runtime_fields` rebuilds `approval_gate.approval_policy`
and `approval_gate.gated_node_names` from opts. Convention: closures in strategy
state must be re-derivable from module metadata.
