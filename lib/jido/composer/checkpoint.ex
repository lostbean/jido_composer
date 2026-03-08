defmodule Jido.Composer.Checkpoint do
  @moduledoc """
  Checkpoint preparation and restore for Composer strategy state.

  Before persisting strategy state, closures must be stripped since they
  cannot be serialized. On restore, they are reattached from the agent
  module's DSL configuration (`strategy_opts`).

  ## Strategy Checkpoint Protocol

  Strategies may implement the following optional callbacks to integrate with
  the checkpoint lifecycle. These are discovered at runtime via
  `function_exported?/3` — no behaviour is required.

  - `replay_directives_from_state/1` — Given deserialized strategy state,
    returns a list of directives needed to resume in-flight operations
    (e.g. re-issue an LLM call or re-dispatch pending tool calls).

  - `prepare_for_checkpoint/1` — Prepares the agent for hibernation by
    stripping non-serializable data. Called before persisting.

  - `reattach_runtime_config/2` — Restores runtime closures and transient
    state from `strategy_opts` after deserialization.

  ## Schema Version

  Current checkpoint schema is `:composer_v1`.
  """

  alias Jido.Agent.Directive
  alias Jido.Composer.Children

  @schema_version :composer_v1

  @valid_transitions %{
    hibernated: [:resuming],
    resuming: [:resumed],
    resumed: []
  }

  @doc """
  Returns the current checkpoint schema version.
  """
  @spec schema_version() :: atom()
  def schema_version, do: @schema_version

  @doc """
  Validates a checkpoint status transition.
  """
  @spec transition_status(atom(), atom()) :: :ok | {:error, {:invalid_transition, atom(), atom()}}
  def transition_status(current, target) do
    if target in Map.get(@valid_transitions, current, []) do
      :ok
    else
      {:error, {:invalid_transition, current, target}}
    end
  end

  @doc """
  Prepares strategy state for checkpoint by stripping non-serializable
  values (closures/functions) from top-level fields and setting checkpoint status.
  """
  @spec prepare_for_checkpoint(map()) :: map()
  def prepare_for_checkpoint(strategy_state) when is_map(strategy_state) do
    strategy_state
    |> Map.new(fn {key, value} ->
      if is_function(value) do
        {key, nil}
      else
        {key, value}
      end
    end)
    |> Map.put_new(:checkpoint_status, :hibernated)
  end

  @doc """
  Reattaches runtime configuration (closures) from strategy_opts.

  Only restores values that are currently nil in the checkpoint state.
  """
  @spec reattach_runtime_config(map(), keyword()) :: map()
  def reattach_runtime_config(checkpoint_state, strategy_opts) when is_map(checkpoint_state) do
    Enum.reduce(strategy_opts, checkpoint_state, fn {key, value}, acc ->
      if is_function(value) and Map.get(acc, key) == nil do
        Map.put(acc, key, value)
      else
        acc
      end
    end)
  end

  @doc """
  Returns SpawnAgent directives for paused children that need re-spawning.
  """
  @spec pending_child_respawns(map()) :: [Directive.SpawnAgent.t()]
  def pending_child_respawns(strategy_state) do
    paused =
      case Map.get(strategy_state, :children) do
        %Children{} = children ->
          Children.paused_refs(children)

        refs when is_map(refs) ->
          Enum.filter(refs, fn {_tag, ref} -> ref.status == :paused end)

        _ ->
          []
      end

    Enum.map(paused, fn {_tag, ref} ->
      %Directive.SpawnAgent{
        agent: ref.agent_module,
        tag: ref.tag,
        opts: %{
          id: ref.agent_id,
          checkpoint_key: ref.checkpoint_key
        }
      }
    end)
  end

  @doc """
  Returns directives needed to replay in-flight operations after checkpoint restore.

  Replays workflow child spawning phases directly, and delegates strategy-specific
  replay to the strategy module's `replay_directives_from_state/1` callback.
  """
  @spec replay_directives(map()) :: [struct()]
  def replay_directives(strategy_state) do
    child_replays = replay_child_phases(strategy_state)
    strategy_replays = replay_strategy_directives(strategy_state)
    child_replays ++ strategy_replays
  end

  defp replay_child_phases(state) do
    case Map.get(state, :children) do
      %Children{} = children ->
        replay_child_phases_from_struct(children)

      _ ->
        replay_child_phases_from_flat(state)
    end
  end

  defp replay_child_phases_from_struct(%Children{} = children) do
    spawning = Children.spawning_tags(children)

    # Fallback: if phases is empty, derive from ChildRef.phase fields
    spawning =
      if spawning == [] do
        children.refs
        |> Enum.filter(fn {_tag, ref} -> Map.get(ref, :phase) == :spawning end)
        |> Enum.map(fn {tag, _} -> tag end)
      else
        spawning
      end

    Enum.flat_map(spawning, fn tag ->
      case Children.get_ref(children, tag) do
        %{agent_module: mod} ->
          [%Directive.SpawnAgent{agent: mod, tag: tag, opts: %{}}]

        _ ->
          []
      end
    end)
  end

  defp replay_child_phases_from_flat(state) do
    refs = Map.get(state, :children, %{})
    phases = Map.get(state, :child_phases, %{})

    # Fallback: if phases is empty, derive from ChildRef.phase fields
    phases =
      if phases == %{} do
        Enum.reduce(refs, %{}, fn {tag, ref}, acc ->
          case Map.get(ref, :phase) do
            nil -> acc
            phase -> Map.put(acc, tag, phase)
          end
        end)
      else
        phases
      end

    Enum.flat_map(phases, fn
      {tag, :spawning} ->
        case Map.get(refs, tag) do
          %{agent_module: mod} ->
            [%Directive.SpawnAgent{agent: mod, tag: tag, opts: %{}}]

          _ ->
            []
        end

      _ ->
        []
    end)
  end

  defp replay_strategy_directives(state) do
    module = Map.get(state, :module)

    if is_atom(module) and module != nil and
         function_exported?(module, :replay_directives_from_state, 1) do
      module.replay_directives_from_state(state)
    else
      []
    end
  end

  @doc """
  Wraps suspend directives with a CheckpointAndStop directive when the suspension
  timeout exceeds the configured `hibernate_after` threshold.

  Returns the original directives list, potentially with CheckpointAndStop appended.
  """
  @spec maybe_add_checkpoint_and_stop([struct()], map()) :: [struct()]
  def maybe_add_checkpoint_and_stop(directives, strategy_state) do
    hibernate_after = Map.get(strategy_state, :hibernate_after)

    if is_integer(hibernate_after) do
      Enum.reduce(directives, directives, fn
        %Jido.Composer.Directive.Suspend{suspension: suspension}, acc ->
          timeout = Map.get(suspension, :timeout, :infinity)

          if is_integer(timeout) and timeout >= hibernate_after do
            checkpoint_directive = %Jido.Composer.Directive.CheckpointAndStop{
              suspension: suspension
            }

            acc ++ [checkpoint_directive]
          else
            acc
          end

        _, acc ->
          acc
      end)
    else
      directives
    end
  end

  @doc """
  Migrates checkpoint state from an older schema version to the current one.
  """
  @spec migrate(map(), non_neg_integer()) :: map()
  def migrate(state, 1), do: state
  def migrate(state, _version), do: state
end
