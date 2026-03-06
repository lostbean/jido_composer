defmodule Jido.Composer.Context do
  @moduledoc """
  Layered context struct separating ambient (read-only), working (mutable),
  and fork functions (applied at agent boundaries).

  Nodes never receive this struct directly — they get a flat map from
  `to_flat_map/1`, with ambient data under the reserved `__ambient__` key.
  """

  defstruct ambient: %{}, working: %{}, fork_fns: %{}

  @type fork_fn :: {module(), atom(), list()}
  @type t :: %__MODULE__{
          ambient: map(),
          working: map(),
          fork_fns: %{atom() => fork_fn()}
        }

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      ambient: Keyword.get(opts, :ambient, %{}),
      working: Keyword.get(opts, :working, %{}),
      fork_fns: Keyword.get(opts, :fork_fns, %{})
    }
  end

  @spec get_ambient(t(), atom()) :: term()
  def get_ambient(%__MODULE__{ambient: ambient}, key) do
    Map.get(ambient, key)
  end

  @spec apply_result(t(), atom(), map()) :: t()
  def apply_result(%__MODULE__{working: working} = ctx, scope, result) do
    %{ctx | working: DeepMerge.deep_merge(working, %{scope => result})}
  end

  @spec fork_for_child(t()) :: t()
  def fork_for_child(%__MODULE__{ambient: ambient, working: working, fork_fns: fns} = ctx) do
    forked_ambient =
      Enum.reduce(fns, ambient, fn {_name, {mod, fun, args}}, acc ->
        apply(mod, fun, [acc, working | args])
      end)

    %{ctx | ambient: forked_ambient}
  end

  @spec to_flat_map(t()) :: map()
  def to_flat_map(%__MODULE__{ambient: ambient, working: working}) do
    Map.put(working, :__ambient__, ambient)
  end

  @spec to_serializable(t()) :: map()
  def to_serializable(%__MODULE__{ambient: ambient, working: working, fork_fns: fns}) do
    %{ambient: ambient, working: working, fork_fns: fns}
  end

  @spec from_serializable(map()) :: t()
  def from_serializable(%{ambient: ambient, working: working} = data) do
    %__MODULE__{
      ambient: ambient,
      working: working,
      fork_fns: Map.get(data, :fork_fns, %{})
    }
  end
end
