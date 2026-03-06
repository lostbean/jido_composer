defmodule Jido.Composer.Workflow.Machine do
  @moduledoc """
  Pure FSM struct at the heart of a Workflow.

  The Machine holds the current state, transition rules, node bindings,
  accumulated context, and execution history. All operations are pure
  functions — no side effects.
  """

  alias Jido.Composer.Error
  alias Jido.Composer.NodeIO

  @default_terminal_states MapSet.new([:done, :failed])

  @enforce_keys [:status, :nodes, :transitions]
  defstruct [
    :status,
    :nodes,
    :transitions,
    terminal_states: @default_terminal_states,
    context: %{},
    history: []
  ]

  @type t :: %__MODULE__{
          status: atom(),
          nodes: %{atom() => struct()},
          transitions: %{{atom(), atom()} => atom()},
          terminal_states: MapSet.t(),
          context: map(),
          history: [{atom(), atom(), integer()}]
        }

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      status: Keyword.fetch!(opts, :initial),
      nodes: Keyword.fetch!(opts, :nodes),
      transitions: Keyword.fetch!(opts, :transitions),
      terminal_states:
        opts
        |> Keyword.get(:terminal_states, [:done, :failed])
        |> MapSet.new(),
      context: Keyword.get(opts, :context, %{}),
      history: []
    }
  end

  @spec current_node(t()) :: struct() | nil
  def current_node(%__MODULE__{status: status, nodes: nodes}) do
    Map.get(nodes, status)
  end

  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status, terminal_states: terminal_states}) do
    MapSet.member?(terminal_states, status)
  end

  @spec transition(t(), atom()) :: {:ok, t()} | {:error, term()}
  def transition(%__MODULE__{status: current, transitions: transitions} = machine, outcome) do
    case lookup_transition(transitions, current, outcome) do
      {:ok, next_state} ->
        {:ok,
         %{machine | status: next_state, history: [{current, outcome, now()} | machine.history]}}

      :error ->
        {:error,
         Error.transition_error(
           "No transition from #{inspect(current)} with outcome #{inspect(outcome)}",
           state: current,
           outcome: outcome
         )}
    end
  end

  @spec apply_result(t(), map() | NodeIO.t()) :: t()
  def apply_result(%__MODULE__{status: status, context: context} = machine, result) do
    resolved = resolve_result(result)
    scoped = %{status => resolved}
    %{machine | context: DeepMerge.deep_merge(context, scoped)}
  end

  defp resolve_result(%NodeIO{} = io), do: NodeIO.to_map(io)
  defp resolve_result(result) when is_map(result), do: result

  # Transition lookup with fallback chain:
  # 1. {state, outcome} — exact match
  # 2. {:_, outcome}    — wildcard state
  # 3. {state, :_}      — wildcard outcome
  # 4. {:_, :_}         — global fallback
  defp lookup_transition(transitions, state, outcome) do
    cond do
      Map.has_key?(transitions, {state, outcome}) ->
        {:ok, Map.fetch!(transitions, {state, outcome})}

      Map.has_key?(transitions, {:_, outcome}) ->
        {:ok, Map.fetch!(transitions, {:_, outcome})}

      Map.has_key?(transitions, {state, :_}) ->
        {:ok, Map.fetch!(transitions, {state, :_})}

      Map.has_key?(transitions, {:_, :_}) ->
        {:ok, Map.fetch!(transitions, {:_, :_})}

      true ->
        :error
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
