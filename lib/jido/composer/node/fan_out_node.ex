defmodule Jido.Composer.Node.FanOutNode do
  @moduledoc """
  Executes multiple child nodes concurrently and merges their results.

  FanOutNode encapsulates parallel execution behind the standard Node interface.
  It appears as a single state to the Workflow FSM but internally spawns
  multiple branches via `Task.async_stream`.

  ## Merge Strategies

  - `:deep_merge` (default) — scopes each branch result under the branch name,
    then deep-merges into a single map
  - Custom function — receives `[{branch_name, result}]` and returns a map

  ## Error Handling

  - `:fail_fast` (default) — returns `{:error, reason}` on first branch failure
  - `:collect_partial` — collects all results, including `{:error, reason}` entries
  """

  alias Jido.Composer.NodeIO

  @behaviour Jido.Composer.Node

  @default_timeout 30_000

  @enforce_keys [:name, :branches]
  defstruct [
    :name,
    :branches,
    :max_concurrency,
    merge: :deep_merge,
    timeout: @default_timeout,
    on_error: :fail_fast
  ]

  @type branch :: {atom(), struct()}
  @type merge :: :deep_merge | (list({atom(), map()}) -> map())

  @type t :: %__MODULE__{
          name: String.t(),
          branches: [branch()],
          merge: merge(),
          timeout: pos_integer() | :infinity,
          on_error: :fail_fast | :collect_partial,
          max_concurrency: pos_integer() | nil
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) do
    name = Keyword.get(opts, :name)
    branches = Keyword.get(opts, :branches)

    cond do
      is_nil(name) ->
        {:error, "name is required"}

      is_nil(branches) || branches == [] ->
        {:error, "branches must be a non-empty keyword list"}

      not all_node_structs?(branches) ->
        {:error, "all branches must be Node structs, not functions"}

      true ->
        {:ok,
         %__MODULE__{
           name: name,
           branches: branches,
           merge: Keyword.get(opts, :merge, :deep_merge),
           timeout: Keyword.get(opts, :timeout, @default_timeout),
           on_error: Keyword.get(opts, :on_error, :fail_fast),
           max_concurrency: Keyword.get(opts, :max_concurrency)
         }}
    end
  end

  @impl true
  @spec run(t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(%__MODULE__{} = node, context, _opts \\ []) do
    concurrency = node.max_concurrency || length(node.branches)

    results =
      node.branches
      |> Task.async_stream(
        fn {branch_name, branch_node} ->
          result = branch_node.__struct__.run(branch_node, context)
          {branch_name, result}
        end,
        timeout: node.timeout,
        on_timeout: :kill_task,
        ordered: true,
        max_concurrency: concurrency
      )
      |> Enum.to_list()

    case process_results(results, node.on_error) do
      {:ok, branch_results} ->
        merged = merge_results(branch_results, node.merge)
        {:ok, merged}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  @spec name(t()) :: String.t()
  def name(%__MODULE__{name: name}), do: name

  @impl true
  @spec description(t()) :: String.t()
  def description(%__MODULE__{branches: branches}) do
    "Fan-out node with #{length(branches)} concurrent branches"
  end

  @impl true
  @spec to_directive(t(), map(), keyword()) :: Jido.Composer.Node.directive_result()
  def to_directive(%__MODULE__{} = node, flat_context, opts) do
    fan_out_id = Keyword.fetch!(opts, :fan_out_id)
    structured_context = Keyword.get(opts, :structured_context)

    all_branches =
      Enum.map(node.branches, fn {branch_name, branch_node} ->
        params = prepare_branch_params(branch_node, flat_context, structured_context)

        directive =
          build_branch_directive(fan_out_id, branch_name, branch_node, params, node.timeout)

        {branch_name, directive}
      end)

    max_concurrency = node.max_concurrency || length(all_branches)
    {to_dispatch, to_queue} = Enum.split(all_branches, max_concurrency)

    dispatched_names = Enum.map(to_dispatch, fn {name, _} -> name end) |> MapSet.new()

    fan_out_state =
      Jido.Composer.FanOut.State.new(fan_out_id, node, dispatched_names, to_queue)

    directives = Enum.map(to_dispatch, fn {_name, directive} -> directive end)
    {:ok, directives, fan_out: fan_out_state}
  end

  @impl true
  @spec to_tool_spec(t()) :: nil
  def to_tool_spec(%__MODULE__{}), do: nil

  defp prepare_branch_params(
         %Jido.Composer.Node.AgentNode{},
         flat_context,
         structured_context
       ) do
    if structured_context do
      structured_context
      |> Jido.Composer.Context.fork_for_child()
      |> Jido.Composer.Context.to_flat_map()
    else
      flat_context
    end
  end

  defp prepare_branch_params(_branch_node, flat_context, _structured_context) do
    flat_context
  end

  defp build_branch_directive(fan_out_id, branch_name, child_node, params, timeout) do
    %Jido.Composer.Directive.FanOutBranch{
      fan_out_id: fan_out_id,
      branch_name: branch_name,
      child_node: child_node,
      params: params,
      result_action: :fan_out_branch_result,
      timeout: timeout
    }
  end

  defp all_node_structs?(branches) do
    Enum.all?(branches, fn {_name, branch} -> is_struct(branch) end)
  end

  defp process_results(results, :fail_fast) do
    case Enum.reduce_while(results, {:ok, []}, fn
           {:ok, {name, {:ok, result}}}, {:ok, acc} ->
             {:cont, {:ok, [{name, result} | acc]}}

           {:ok, {name, {:ok, result, _outcome}}}, {:ok, acc} ->
             {:cont, {:ok, [{name, result} | acc]}}

           {:ok, {_name, {:error, reason}}}, _acc ->
             {:halt, {:error, {:branch_failed, reason}}}

           {:exit, reason}, _acc ->
             {:halt, {:error, {:branch_crashed, reason}}}
         end) do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = error -> error
    end
  end

  defp process_results(results, :collect_partial) do
    branch_results =
      results
      |> Enum.reduce([], fn
        {:ok, {name, {:ok, result}}}, acc -> [{name, result} | acc]
        {:ok, {name, {:ok, result, _outcome}}}, acc -> [{name, result} | acc]
        {:ok, {name, {:error, reason}}}, acc -> [{name, {:error, reason}} | acc]
        {:exit, _reason}, acc -> acc
      end)
      |> Enum.reverse()

    {:ok, branch_results}
  end

  @doc """
  Merges branch results using the specified merge strategy.

  When called from the strategy with a completed_results map, converts to
  the keyword-list format expected by the merge logic.
  """
  @spec merge_results(%{atom() => term()} | [{atom(), term()}], merge()) :: map()
  def merge_results(branch_results, merge) when is_map(branch_results) do
    merge_results(Enum.to_list(branch_results), merge)
  end

  def merge_results(branch_results, :deep_merge) do
    Enum.reduce(branch_results, %{}, fn
      {name, %NodeIO{} = io}, acc ->
        DeepMerge.deep_merge(acc, %{name => NodeIO.to_map(io)})

      {name, result}, acc when is_map(result) ->
        DeepMerge.deep_merge(acc, %{name => result})

      {name, result}, acc ->
        Map.put(acc, name, result)
    end)
  end

  def merge_results(branch_results, merge_fn) when is_function(merge_fn, 1) do
    merge_fn.(branch_results)
  end
end
