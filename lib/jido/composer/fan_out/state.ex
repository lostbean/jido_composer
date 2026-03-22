defmodule Jido.Composer.FanOut.State do
  @moduledoc """
  Typed sub-state for tracking FanOut branch execution.

  Replaces the bare map `pending_fan_out` in Workflow Strategy.
  Encapsulates branch completion, suspension, queueing, and merge logic.
  """

  alias Jido.Composer.Suspension

  @derive Jason.Encoder

  @enforce_keys [:id, :node]
  defstruct [
    :id,
    :node,
    :total_branches,
    pending_branches: MapSet.new(),
    completed_results: %{},
    suspended_branches: %{},
    queued_branches: [],
    merge: :deep_merge,
    on_error: :fail_fast
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          node: struct(),
          total_branches: non_neg_integer() | nil,
          pending_branches: MapSet.t(),
          completed_results: %{atom() => term()},
          suspended_branches: %{atom() => %{suspension: Suspension.t(), partial_result: term()}},
          queued_branches: [{atom(), term()}],
          merge: atom(),
          on_error: :fail_fast | :collect_partial
        }

  @doc "Creates a new FanOut.State from dispatched and queued branches."
  @spec new(String.t(), struct(), MapSet.t(), [{atom(), term()}]) :: t()
  def new(id, node, dispatched_names, queued_branches) do
    %__MODULE__{
      id: id,
      node: node,
      total_branches: compute_total_branches(node),
      pending_branches: dispatched_names,
      completed_results: %{},
      suspended_branches: %{},
      queued_branches: queued_branches,
      merge: node.merge,
      on_error: node.on_error
    }
  end

  defp compute_total_branches(%{branches: branches}) when is_list(branches), do: length(branches)
  defp compute_total_branches(%{total_branches: n}) when is_integer(n), do: n
  defp compute_total_branches(_), do: nil

  @doc "Record a successful branch completion."
  @spec branch_completed(t(), atom(), term()) :: t()
  def branch_completed(%__MODULE__{} = state, branch_name, result) do
    %{
      state
      | completed_results: Map.put(state.completed_results, branch_name, result),
        pending_branches: MapSet.delete(state.pending_branches, branch_name)
    }
  end

  @doc "Record a branch suspension."
  @spec branch_suspended(t(), atom(), Suspension.t(), term()) :: t()
  def branch_suspended(%__MODULE__{} = state, branch_name, suspension, partial_result) do
    %{
      state
      | pending_branches: MapSet.delete(state.pending_branches, branch_name),
        suspended_branches:
          Map.put(state.suspended_branches, branch_name, %{
            suspension: suspension,
            partial_result: partial_result
          })
    }
  end

  @doc "Record a branch error (for :collect_partial mode)."
  @spec branch_error(t(), atom(), term()) :: t()
  def branch_error(%__MODULE__{} = state, branch_name, reason) do
    %{
      state
      | completed_results: Map.put(state.completed_results, branch_name, {:error, reason}),
        pending_branches: MapSet.delete(state.pending_branches, branch_name)
    }
  end

  @doc """
  Drain queued branches into available slots.
  Returns `{updated_state, to_dispatch}` where `to_dispatch` is a list of
  `{branch_name, directive}` tuples.
  """
  @spec drain_queue(t()) :: {t(), [{atom(), term()}]}
  def drain_queue(%__MODULE__{queued_branches: []} = state), do: {state, []}

  def drain_queue(%__MODULE__{} = state) do
    max =
      (state.node.max_concurrency || state.total_branches || 0) -
        MapSet.size(state.pending_branches)

    if max <= 0 do
      {state, []}
    else
      {to_dispatch, remaining} = Enum.split(state.queued_branches, max)
      new_pending_names = Enum.map(to_dispatch, fn {name, _} -> name end)

      pending =
        Enum.reduce(new_pending_names, state.pending_branches, &MapSet.put(&2, &1))

      state = %{state | pending_branches: pending, queued_branches: remaining}
      {state, to_dispatch}
    end
  end

  @doc "Returns the completion status of the fan-out."
  @spec completion_status(t()) :: :all_done | :suspended | :in_progress
  def completion_status(%__MODULE__{} = state) do
    no_pending = MapSet.size(state.pending_branches) == 0
    no_queued = state.queued_branches == []
    has_suspended = state.suspended_branches != %{}

    cond do
      no_pending and no_queued and not has_suspended -> :all_done
      no_pending and no_queued and has_suspended -> :suspended
      true -> :in_progress
    end
  end

  @doc "Merge completed results using the configured merge strategy."
  @spec merge_results(t()) :: map()
  def merge_results(%__MODULE__{} = state) do
    do_merge(state.completed_results, state.merge)
  end

  defp do_merge(completed_results, :deep_merge) do
    completed_results
    |> Enum.to_list()
    |> Enum.reduce(%{}, fn
      {name, %Jido.Composer.NodeIO{} = io}, acc ->
        DeepMerge.deep_merge(acc, %{name => Jido.Composer.NodeIO.to_map(io)})

      {name, result}, acc when is_map(result) ->
        DeepMerge.deep_merge(acc, %{name => result})

      {name, result}, acc ->
        Map.put(acc, name, result)
    end)
  end

  defp do_merge(completed_results, :ordered_list) do
    completed_results
    |> Enum.to_list()
    |> Enum.sort_by(fn {name, _} ->
      name |> Atom.to_string() |> String.replace_prefix("item_", "") |> String.to_integer()
    end)
    |> Enum.map(fn {_name, result} -> result end)
    |> then(&%{results: &1})
  end

  defp do_merge(completed_results, merge_fn) when is_function(merge_fn, 1) do
    completed_results |> Enum.to_list() |> merge_fn.()
  end

  @doc "Check if a suspended branch matches the given suspension_id."
  @spec has_suspended_branch?(t(), String.t()) :: boolean()
  def has_suspended_branch?(%__MODULE__{suspended_branches: branches}, suspension_id) do
    Enum.any?(branches, fn {_name, %{suspension: %Suspension{id: id}}} ->
      id == suspension_id
    end)
  end

  @doc "Find a suspended branch by suspension_id."
  @spec find_suspended_branch(t(), String.t()) :: {atom(), map()} | nil
  def find_suspended_branch(%__MODULE__{suspended_branches: branches}, suspension_id) do
    Enum.find(branches, fn {_name, %{suspension: %Suspension{id: id}}} ->
      id == suspension_id
    end)
  end

  @doc "Resume a suspended branch by removing it from suspended_branches."
  @spec resume_branch(t(), atom()) :: t()
  def resume_branch(%__MODULE__{} = state, branch_name) do
    %{state | suspended_branches: Map.delete(state.suspended_branches, branch_name)}
  end
end
