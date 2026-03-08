defmodule Jido.Composer.ToolConcurrency do
  @moduledoc """
  Typed sub-state for tracking tool call concurrency in the Orchestrator.

  Replaces flat `pending_tool_calls`, `completed_tool_results`,
  `queued_tool_calls`, and `max_tool_concurrency` fields in Orchestrator Strategy.
  """

  @derive Jason.Encoder

  defstruct pending: [],
            completed: [],
            queued: [],
            max_concurrency: nil,
            max_queue_depth: nil

  @type t :: %__MODULE__{
          pending: [String.t()],
          completed: [map()],
          queued: [map()],
          max_concurrency: non_neg_integer() | nil,
          max_queue_depth: non_neg_integer() | nil
        }

  @doc "Creates a new ToolConcurrency state."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      max_concurrency: Keyword.get(opts, :max_concurrency),
      max_queue_depth: Keyword.get(opts, :max_queue_depth)
    }
  end

  @doc """
  Splits calls into those to dispatch immediately and those to queue,
  respecting the concurrency limit.

  Returns `{to_dispatch, to_queue}`.
  """
  @spec split_for_dispatch(t(), [map()]) :: {[map()], [map()]}
  def split_for_dispatch(%__MODULE__{max_concurrency: nil}, calls), do: {calls, []}

  def split_for_dispatch(%__MODULE__{max_concurrency: max}, calls) when max < length(calls) do
    Enum.split(calls, max)
  end

  def split_for_dispatch(%__MODULE__{}, calls), do: {calls, []}

  @doc """
  Records dispatched call IDs and queued calls, resetting completed results.
  """
  @spec dispatch(t(), [String.t()], [map()]) :: t()
  def dispatch(%__MODULE__{} = state, dispatched_ids, queued_calls) do
    %{state | pending: dispatched_ids, completed: [], queued: queued_calls}
  end

  @doc """
  Records a completed tool result and removes its call_id from pending.
  """
  @spec record_result(t(), String.t(), map()) :: t()
  def record_result(%__MODULE__{} = state, call_id, result) do
    %{
      state
      | pending: List.delete(state.pending, call_id),
        completed: state.completed ++ [result]
    }
  end

  @doc """
  Adds a call ID to pending (e.g., when an approved call is dispatched).
  """
  @spec add_pending(t(), String.t()) :: t()
  def add_pending(%__MODULE__{} = state, call_id) do
    %{state | pending: state.pending ++ [call_id]}
  end

  @doc """
  Adds a call to the queue (e.g., when approved but at capacity).

  Returns `{:ok, state}` on success, or `{:error, :queue_full}` if the queue
  has reached `max_queue_depth`.
  """
  @spec enqueue(t(), map()) :: {:ok, t()} | {:error, :queue_full}
  def enqueue(%__MODULE__{max_queue_depth: max} = state, _call)
      when is_integer(max) and length(state.queued) >= max do
    {:error, :queue_full}
  end

  def enqueue(%__MODULE__{} = state, call) do
    {:ok, %{state | queued: state.queued ++ [call]}}
  end

  @doc """
  Returns true if at max concurrency capacity.
  """
  @spec at_capacity?(t()) :: boolean()
  def at_capacity?(%__MODULE__{max_concurrency: nil}), do: false

  def at_capacity?(%__MODULE__{max_concurrency: max, pending: pending}) do
    length(pending) >= max
  end

  @doc """
  Drains queued calls into available concurrency slots.

  Returns `{updated_state, to_dispatch}` where `to_dispatch` is a list of
  call maps ready to be dispatched.
  """
  @spec drain_queue(t()) :: {t(), [map()]}
  def drain_queue(%__MODULE__{queued: []} = state), do: {state, []}

  def drain_queue(%__MODULE__{} = state) do
    max = state.max_concurrency || length(state.queued)
    slots = max - length(state.pending)

    if slots <= 0 do
      {state, []}
    else
      {to_dispatch, remaining} = Enum.split(state.queued, slots)
      new_ids = Enum.map(to_dispatch, & &1.id)

      state = %{
        state
        | pending: state.pending ++ new_ids,
          queued: remaining
      }

      {state, to_dispatch}
    end
  end

  @doc "Returns true when no tool calls are pending or queued."
  @spec all_clear?(t()) :: boolean()
  def all_clear?(%__MODULE__{pending: [], queued: []}), do: true
  def all_clear?(%__MODULE__{}), do: false

  @doc "Returns true when there are pending tool calls."
  @spec has_pending?(t()) :: boolean()
  def has_pending?(%__MODULE__{pending: []}), do: false
  def has_pending?(%__MODULE__{}), do: true
end
