# Limitation: OTP Hibernate Not Supported at Runtime

**Status:** Blocked — requires changes in `jido` AgentServer

## Description

The three-tier persistence model (see [persistence.md](../hitl/persistence.md))
defines an intermediate tier between live-wait and full checkpoint: OTP
hibernate via `:proc_lib.hibernate/3`. This compresses the GenServer heap to
near-zero memory while keeping the process alive and responsive to messages.

The Suspend directive already has a `hibernate` field with the correct semantics
(`false`, `true`, `%{after: ms}`), and the
[suspend_exec.ex](../../../lib/jido/composer/directive/suspend_exec.ex) logs
the intent. However, it cannot act on it because OTP hibernate requires
returning `:hibernate` as a third element from a GenServer callback
(`{:noreply, state, :hibernate}`), which directive executors cannot do.

The AgentServer drain loop in `jido` processes `DirectiveExec.exec` results and
only handles three return shapes:

| Return                | Drain Loop Action  |
| --------------------- | ------------------ |
| `{:ok, state}`        | Continue draining  |
| `{:async, ref, st}`   | Continue draining  |
| `{:stop, reason, st}` | Stop the GenServer |

There is no `{:hibernate, state}` variant, so no directive can trigger OTP
hibernate.

## Use Cases

- **Moderate-duration suspensions (30s to 5min):** Agents waiting for human
  input, rate-limit backoff, or external webhook callbacks. Full checkpoint is
  too expensive (serialization + process restart on resume), but keeping the
  full agent heap in memory wastes resources.

- **High-concurrency deployments:** Systems running hundreds of suspended agents
  simultaneously. OTP hibernate would reduce per-agent memory from full heap
  to near-zero, enabling significantly higher agent density.

- **Latency-sensitive resumption:** Sub-millisecond resume from OTP hibernate
  vs. thaw + process start from a full checkpoint. Critical for interactive
  HITL workflows where human response times are seconds, not minutes.

## Requirements

Two options exist, both requiring changes in `jido`:

### Option A: New DirectiveExec Return Type (precise control)

1. **Add `{:hibernate, state}` to the drain loop.** In
   `AgentServer.handle_info(:drain, ...)`, add a fourth case:

   ```elixir
   case result do
     {:ok, s2}           -> continue_draining(s2)
     {:async, _ref, s2}  -> continue_draining(s2)
     {:hibernate, s2}    -> {:noreply, s2, :hibernate}  # NEW
     {:stop, reason, s2} -> {:stop, reason, ...}
   end
   ```

2. **Update the `DirectiveExec` protocol** to document `{:hibernate, state}` as
   a valid return.

3. **Update `suspend_exec.ex`** in jido_composer to return
   `{:hibernate, state}` when `hibernate: true`.

### Option B: `hibernate_after` GenServer Option (passive, simpler)

1. **Pass `hibernate_after` through `AgentServer.start_link`.** GenServer
   natively supports `hibernate_after: ms` which automatically hibernates the
   process after a period of inactivity:

   ```elixir
   GenServer.start_link(__MODULE__, agent_opts, [name: name, hibernate_after: 15_000])
   ```

2. **Add `hibernate_after` to `extract_genserver_opts`** in AgentServer so it
   flows through from agent configuration.

3. **No changes needed in jido_composer.** The Suspend directive's `hibernate`
   field remains a hint. Actual hibernation happens passively via GenServer's
   built-in timer mechanism.

### Recommendation

Option B is the path of least resistance — a 2-line change in `jido` with no
protocol modifications. It covers the primary use case: a suspended agent
naturally goes idle, and `hibernate_after` kicks in automatically. The downside
is lack of immediate-hibernate control (there is always a delay), but for most
practical scenarios the delay is acceptable.

Option A provides precise control and aligns with the directive model, but
requires protocol changes and careful handling in the drain loop.
