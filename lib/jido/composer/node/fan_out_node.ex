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
    merge: :deep_merge,
    timeout: @default_timeout,
    on_error: :fail_fast
  ]

  @type branch :: {atom(), struct() | (map() -> Jido.Composer.Node.result())}
  @type merge :: :deep_merge | (list({atom(), map()}) -> map())

  @type t :: %__MODULE__{
          name: String.t(),
          branches: [branch()],
          merge: merge(),
          timeout: pos_integer() | :infinity,
          on_error: :fail_fast | :collect_partial
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

      true ->
        {:ok,
         %__MODULE__{
           name: name,
           branches: branches,
           merge: Keyword.get(opts, :merge, :deep_merge),
           timeout: Keyword.get(opts, :timeout, @default_timeout),
           on_error: Keyword.get(opts, :on_error, :fail_fast)
         }}
    end
  end

  @impl true
  @spec run(t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(%__MODULE__{} = node, context, _opts \\ []) do
    results =
      node.branches
      |> Task.async_stream(
        fn {branch_name, branch} ->
          result = execute_branch(branch, context)
          {branch_name, result}
        end,
        timeout: node.timeout,
        on_timeout: :kill_task,
        ordered: true,
        max_concurrency: length(node.branches)
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

  defp execute_branch(branch, context) when is_function(branch, 1) do
    branch.(context)
  end

  defp execute_branch(%mod{} = node, context) do
    mod.run(node, context)
  end

  defp process_results(results, :fail_fast) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, {name, {:ok, result}}}, {:ok, acc} ->
        {:cont, {:ok, acc ++ [{name, result}]}}

      {:ok, {name, {:ok, result, _outcome}}}, {:ok, acc} ->
        {:cont, {:ok, acc ++ [{name, result}]}}

      {:ok, {_name, {:error, reason}}}, _acc ->
        {:halt, {:error, {:branch_failed, reason}}}

      {:exit, reason}, _acc ->
        {:halt, {:error, {:branch_crashed, reason}}}
    end)
  end

  defp process_results(results, :collect_partial) do
    branch_results =
      Enum.reduce(results, [], fn
        {:ok, {name, {:ok, result}}}, acc -> acc ++ [{name, result}]
        {:ok, {name, {:ok, result, _outcome}}}, acc -> acc ++ [{name, result}]
        {:ok, {name, {:error, reason}}}, acc -> acc ++ [{name, {:error, reason}}]
        {:exit, _reason}, acc -> acc
      end)

    {:ok, branch_results}
  end

  defp merge_results(branch_results, :deep_merge) do
    Enum.reduce(branch_results, %{}, fn
      {name, %NodeIO{} = io}, acc ->
        DeepMerge.deep_merge(acc, %{name => NodeIO.to_map(io)})

      {name, result}, acc when is_map(result) ->
        DeepMerge.deep_merge(acc, %{name => result})

      {name, result}, acc ->
        Map.put(acc, name, result)
    end)
  end

  defp merge_results(branch_results, merge_fn) when is_function(merge_fn, 1) do
    merge_fn.(branch_results)
  end
end
