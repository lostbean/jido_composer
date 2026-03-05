defmodule Jido.Composer.Node.ActionNode do
  @moduledoc """
  Wraps a `Jido.Action` module as a Node.

  ActionNode is a thin adapter — it delegates execution to the action module
  via `Jido.Exec.run/2` and metadata to the action's `name/0`, `description/0`,
  and `schema/0` callbacks.

  ActionNode returns raw results. Scoping (storing results under a namespace key)
  is the responsibility of the composition layer (Machine/Strategy), not the node.
  """

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

  @spec run(t(), map(), keyword()) :: Jido.Composer.Node.result()
  def run(%__MODULE__{action_module: action_module}, context, opts \\ []) do
    case Jido.Exec.run(action_module, context, opts) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec name(t()) :: String.t()
  def name(%__MODULE__{action_module: mod}), do: mod.name()

  @spec description(t()) :: String.t()
  def description(%__MODULE__{action_module: mod}), do: mod.description()

  @spec schema(t()) :: keyword() | nil
  def schema(%__MODULE__{action_module: mod}), do: mod.schema()

  defp action_module?(module) do
    Code.ensure_loaded?(module) && function_exported?(module, :run, 2)
  end
end
