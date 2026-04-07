defmodule Jido.Composer.Node.ActionNode do
  @moduledoc """
  Wraps a `Jido.Action` module as a Node.

  ActionNode is a thin adapter — it delegates execution to the action module
  via `Jido.Exec.run/2` and metadata to the action's `name/0`, `description/0`,
  and `schema/0` callbacks.

  ActionNode returns raw results. Scoping (storing results under a namespace key)
  is the responsibility of the composition layer (Machine/Strategy), not the node.
  """

  @behaviour Jido.Composer.Node

  @enforce_keys [:action_module]
  defstruct [:action_module, opts: []]

  @type t :: %__MODULE__{
          action_module: module(),
          opts: keyword()
        }

  @spec new(module(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(action_module, opts \\ []) do
    if action_module?(action_module) do
      {:ok, %__MODULE__{action_module: action_module, opts: opts}}
    else
      {:error, "#{inspect(action_module)} is not a valid Jido.Action module"}
    end
  end

  @impl true
  @spec run(t(), map(), keyword()) :: Jido.Composer.Node.result()
  def run(%__MODULE__{action_module: action_module}, context, opts \\ []) do
    case Jido.Exec.run(action_module, context, opts) do
      {:ok, result} -> {:ok, result}
      {:ok, result, outcome} -> {:ok, result, outcome}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  @spec name(t()) :: String.t()
  def name(%__MODULE__{action_module: mod}), do: mod.name()

  @impl true
  @spec description(t()) :: String.t()
  def description(%__MODULE__{action_module: mod}), do: mod.description()

  @impl true
  @spec schema(t()) :: keyword() | nil
  def schema(%__MODULE__{action_module: mod}), do: mod.schema()

  @impl true
  @spec to_directive(t(), map(), keyword()) :: Jido.Composer.Node.directive_result()
  def to_directive(%__MODULE__{action_module: action_module}, flat_context, opts) do
    result_action = Keyword.get(opts, :result_action, :workflow_node_result)
    meta = Keyword.get(opts, :meta, %{})

    instruction = %Jido.Instruction{
      action: action_module,
      params: flat_context
    }

    directive = %Jido.Agent.Directive.RunInstruction{
      instruction: instruction,
      result_action: result_action,
      meta: meta
    }

    {:ok, [directive]}
  end

  @impl true
  @spec to_tool_spec(t()) :: map()
  def to_tool_spec(%__MODULE__{action_module: mod}) do
    %{
      name: mod.name(),
      description: mod.description(),
      parameter_schema: Jido.Action.Tool.build_parameters_schema(mod.schema())
    }
  end

  defp action_module?(module) do
    match?({:module, _}, Code.ensure_compiled(module)) && function_exported?(module, :run, 2)
  end
end
