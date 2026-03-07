defmodule Jido.Composer.Checkpoint do
  @moduledoc """
  Checkpoint preparation and restore for Composer strategy state.

  Before persisting strategy state, closures must be stripped since they
  cannot be serialized. On restore, they are reattached from the agent
  module's DSL configuration (`strategy_opts`).

  ## Schema Version

  Current checkpoint schema is `:composer_v3`. Migrations:
  - v1 → v2: adds `children` field (empty map default)
  - v2 → v3: adds `checkpoint_status` and `child_phases` fields
  """

  alias Jido.Agent.Directive

  @schema_version :composer_v3

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
    strategy_state
    |> Map.get(:children, %{})
    |> Enum.filter(fn {_tag, ref} -> ref.status == :paused end)
    |> Enum.map(fn {_tag, ref} ->
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
  """
  @spec replay_directives(map()) :: [struct()]
  def replay_directives(strategy_state) do
    replay_child_phases(strategy_state)
  end

  defp replay_child_phases(state) do
    state
    |> Map.get(:child_phases, %{})
    |> Enum.flat_map(fn
      {tag, :spawning} ->
        case get_in(state, [:children, tag]) do
          %{agent_module: mod} ->
            [%Directive.SpawnAgent{agent: mod, tag: tag, opts: %{}}]

          _ ->
            []
        end

      {_tag, :awaiting_result} ->
        []

      _ ->
        []
    end)
  end

  @doc """
  Migrates checkpoint state from an older schema version to the current one.
  """
  @spec migrate(map(), non_neg_integer()) :: map()
  def migrate(state, version)

  def migrate(state, v) when v < 1 do
    migrate(state, 1)
  end

  def migrate(state, 1) do
    state
    |> Map.put_new(:children, %{})
    |> migrate(2)
  end

  def migrate(state, 2) do
    state
    |> Map.put_new(:checkpoint_status, :hibernated)
    |> Map.put_new(:child_phases, %{})
    |> migrate(3)
  end

  def migrate(state, 3), do: state

  def migrate(state, _version), do: state
end
