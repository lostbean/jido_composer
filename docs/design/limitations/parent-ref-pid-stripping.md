# Limitation: ParentRef PID Not Stripped on Checkpoint

**Status:** Blocked — requires fix in `jido` dependency

## Description

When a child agent checkpoints via `Jido.Persist.hibernate/2`, the
`__parent__` field in `agent.state` contains a `ParentRef` struct with a `pid`
field. This PID is not stripped during checkpointing. The existing
`enforce_checkpoint_invariants/2` in `Jido.Persist` already strips `__thread__`
but does not handle `__parent__`.

The `__parent__` field lives at the `agent.state` level, outside the strategy
state that jido_composer controls. The `Checkpoint.prepare_for_checkpoint/1`
function in jido_composer operates only on the `__strategy__` map, so it cannot
reach or modify `__parent__`.

## Use Cases

- **ETF storage (current):** Works but stores a stale PID. The stale PID is
  harmless because `SpawnAgent` re-populates `__parent__` with a fresh
  `ParentRef` on resume. Technically incorrect but functionally safe.

- **JSON-based storage adapters (future):** Would crash at serialization time
  because PIDs are not JSON-representable.

- **Cross-node / distributed restore:** ETF-encoded PIDs embed the originating
  node name. A restored PID would reference a non-existent process on a
  potentially non-existent node, which could cause confusing failures if the
  stale PID is accessed before `SpawnAgent` overwrites it.

- **Checkpoint inspection / debugging:** Tools that read checkpoints would
  encounter a meaningless PID, complicating debugging of persistence issues.

## Requirements

The fix belongs in `Jido.Persist` (the `jido` dependency), not in
jido_composer:

1. **Strip `__parent__.pid` during checkpoint.** In
   `Jido.Persist.enforce_checkpoint_invariants/2` (or
   `Jido.Persist.default_checkpoint/3` at ~line 337), set the `pid` field to
   `nil` when a `ParentRef` is present in state:

   ```elixir
   defp strip_parent_pid(%{__parent__: %ParentRef{} = ref} = state) do
     Map.put(state, :__parent__, %{ref | pid: nil})
   end
   defp strip_parent_pid(state), do: state
   ```

2. **Preserve serializable fields.** The `id`, `tag`, and `meta` fields in
   `ParentRef` are serializable and useful for restore context — only `pid`
   should be nil'd.

3. **No restore-side changes needed.** `SpawnAgent` already re-populates
   `__parent__` with a fresh `ParentRef` containing the new parent PID, so
   restoring a nil'd PID works correctly without additional logic.
