defmodule Jido.Composer.Node.MapNode do
  @moduledoc """
  Applies the same action to each element of a runtime-determined list.

  MapNode implements the **traverse** composition constructor — it takes a
  collection from context (resolved via the `over` path) and runs a single
  action against every element. Results are collected as an ordered list
  under `%{results: [...]}`.

  Unlike `FanOutNode` (which runs N different branches known at definition
  time), MapNode runs one action N times over a collection discovered at
  runtime.

  ## Options

  - `:name` — state name (required)
  - `:over` — context key or path to the list (`atom()` or `[atom()]`)
  - `:action` — `Jido.Action` module to run per element
  - `:max_concurrency` — limit parallel tasks (default: list length)
  - `:timeout` — per-element timeout in ms (default: 30_000)
  - `:on_error` — `:fail_fast` (default) or `:collect_partial`

  ## Example

      {:ok, map_node} = MapNode.new(
        name: :process,
        over: [:extract, :items],
        action: DoubleValueAction
      )

      # Use in a workflow:
      nodes: %{
        extract: ExtractAction,
        process: map_node,
        aggregate: AggregateAction
      }

      # After execution:
      # ctx[:process][:results] => [%{value: 2}, %{value: 4}, %{value: 6}]

  ## Input Preparation

  Each element from the collection is prepared as action params:

  - **Map elements** are merged directly into the flattened context
    (`Map.merge(flat_context, element)`), so the action receives both the
    element's keys and the upstream context.
  - **Non-map elements** (integers, strings, etc.) are wrapped as
    `%{item: element}` and merged into the context.

  ## Edge Cases

  - **Empty list**: produces `%{results: []}` and completes with `:ok`.
  - **Missing key**: if the `over` path doesn't resolve to a list (key is
    missing, value is `nil`, or value is not a list), it's treated as an
    empty list.
  - **Nested path**: `over: [:step_a, :sub_key, :items]` uses `get_in/2`
    to traverse arbitrarily deep context structures.
  """

  @behaviour Jido.Composer.Node

  alias Jido.Composer.Directive.FanOutBranch
  alias Jido.Composer.FanOut.State, as: FanOutState

  @default_timeout 30_000

  @enforce_keys [:name, :over, :action]
  defstruct [
    :name,
    :over,
    :action,
    :max_concurrency,
    merge: :ordered_list,
    on_error: :fail_fast,
    timeout: @default_timeout
  ]

  @type t :: %__MODULE__{
          name: atom(),
          over: atom() | [atom()],
          action: module(),
          max_concurrency: pos_integer() | nil,
          merge: :ordered_list,
          on_error: :fail_fast | :collect_partial,
          timeout: pos_integer()
        }

  defmodule EmptyResult do
    @moduledoc false
    use Jido.Action,
      name: "map_node_empty_result",
      description: "Returns empty results for an empty MapNode collection",
      schema: []

    def run(_params, _context), do: {:ok, %{results: []}}
  end

  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) do
    name = Keyword.get(opts, :name)
    over = Keyword.get(opts, :over)
    action = Keyword.get(opts, :action)

    cond do
      is_nil(name) ->
        {:error, "name is required"}

      is_nil(over) ->
        {:error, "over is required"}

      is_nil(action) ->
        {:error, "action is required"}

      not action_module?(action) ->
        {:error, "#{inspect(action)} is not a valid Jido.Action module"}

      Keyword.get(opts, :on_error, :fail_fast) not in [:fail_fast, :collect_partial] ->
        {:error, "on_error must be :fail_fast or :collect_partial"}

      true ->
        {:ok,
         %__MODULE__{
           name: name,
           over: over,
           action: action,
           max_concurrency: Keyword.get(opts, :max_concurrency),
           timeout: Keyword.get(opts, :timeout, @default_timeout),
           on_error: Keyword.get(opts, :on_error, :fail_fast)
         }}
    end
  end

  @impl true
  @spec run(t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(%__MODULE__{} = node, context, _opts \\ []) do
    items = resolve_items(context, node.over)

    if items == [] do
      {:ok, %{results: []}}
    else
      concurrency = node.max_concurrency || length(items)

      results =
        items
        |> Enum.with_index()
        |> Task.async_stream(
          fn {element, _index} ->
            element_params = prepare_element_params(element)
            Jido.Exec.run(node.action, element_params)
          end,
          timeout: node.timeout,
          on_timeout: :kill_task,
          ordered: true,
          max_concurrency: concurrency
        )
        |> Enum.to_list()

      case process_results(results, node.on_error) do
        {:ok, ordered_results} -> {:ok, %{results: ordered_results}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  @spec name(t()) :: String.t()
  def name(%__MODULE__{name: name}), do: to_string(name)

  @impl true
  @spec description(t()) :: String.t()
  def description(%__MODULE__{action: action, over: over}) do
    over_str = if is_list(over), do: Enum.join(over, "."), else: to_string(over)
    "Map #{inspect(action)} over #{over_str}"
  end

  @impl true
  @spec to_directive(t(), map(), keyword()) :: Jido.Composer.Node.directive_result()
  def to_directive(%__MODULE__{} = node, flat_context, opts) do
    fan_out_id = Keyword.fetch!(opts, :fan_out_id)
    items = resolve_items(flat_context, node.over)

    if items == [] do
      result_action = Keyword.get(opts, :result_action, :workflow_node_result)

      directive = %Jido.Agent.Directive.RunInstruction{
        instruction: %Jido.Instruction{action: EmptyResult, params: flat_context},
        result_action: result_action
      }

      {:ok, [directive]}
    else
      all_branches =
        items
        |> Enum.with_index()
        |> Enum.map(fn {element, index} ->
          branch_name = item_branch_name(index)
          element_params = prepare_element_params(element)
          params = Map.merge(flat_context, element_params)

          directive = %FanOutBranch{
            fan_out_id: fan_out_id,
            branch_name: branch_name,
            instruction: %Jido.Instruction{
              action: node.action,
              params: params
            },
            result_action: :fan_out_branch_result,
            timeout: node.timeout
          }

          {branch_name, directive}
        end)

      max_concurrency = node.max_concurrency || length(all_branches)
      {to_dispatch, to_queue} = Enum.split(all_branches, max_concurrency)

      dispatched_names = Enum.map(to_dispatch, fn {name, _} -> name end) |> MapSet.new()

      fan_out_state = FanOutState.new(fan_out_id, node, dispatched_names, to_queue)

      directives = Enum.map(to_dispatch, fn {_name, directive} -> directive end)
      {:ok, directives, fan_out: fan_out_state}
    end
  end

  @impl true
  @spec to_tool_spec(t()) :: nil
  def to_tool_spec(%__MODULE__{}), do: nil

  # -- Private helpers --

  defp resolve_items(context, over) when is_atom(over) do
    case Map.get(context, over) do
      items when is_list(items) -> items
      _ -> []
    end
  end

  defp resolve_items(context, over) when is_list(over) do
    case get_in(context, over) do
      items when is_list(items) -> items
      _ -> []
    end
  end

  defp prepare_element_params(element) when is_map(element), do: element
  defp prepare_element_params(element), do: %{item: element}

  defp process_results(results, :fail_fast) do
    case Enum.reduce_while(results, {:ok, []}, fn
           {:ok, {:ok, result}}, {:ok, acc} ->
             {:cont, {:ok, [result | acc]}}

           {:ok, {:error, reason}}, _acc ->
             {:halt, {:error, {:element_failed, reason}}}

           {:exit, reason}, _acc ->
             {:halt, {:error, {:element_crashed, reason}}}
         end) do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _} = error -> error
    end
  end

  defp process_results(results, :collect_partial) do
    ordered =
      Enum.map(results, fn
        {:ok, {:ok, result}} -> result
        {:ok, {:error, reason}} -> {:error, reason}
        {:exit, reason} -> {:error, {:crashed, reason}}
      end)

    {:ok, ordered}
  end

  # Safe: index is always a non-negative integer from Enum.with_index/1.
  # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
  defp item_branch_name(index), do: :"item_#{index}"

  defp action_module?(module) do
    Code.ensure_loaded?(module) && function_exported?(module, :run, 2)
  end
end
