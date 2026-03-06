defmodule Jido.Composer.NodeIO do
  @moduledoc """
  Typed envelope for node output.

  Wraps node results with type metadata (`:map`, `:text`, or `:object`)
  while preserving the monoidal map structure via `to_map/1`.

  ## Types

  - `:map` — a plain map, passes through `to_map/1` unchanged
  - `:text` — a string, wrapped as `%{text: value}` by `to_map/1`
  - `:object` — a structured object with optional schema, wrapped as `%{object: value}`
  """

  @type io_type :: :map | :text | :object

  @type t :: %__MODULE__{
          type: io_type(),
          value: term(),
          schema: map() | nil,
          meta: map()
        }

  @derive Jason.Encoder
  defstruct [:type, :value, schema: nil, meta: %{}]

  @spec map(map()) :: t()
  def map(value) when is_map(value),
    do: %__MODULE__{type: :map, value: value}

  @spec text(String.t()) :: t()
  def text(value) when is_binary(value),
    do: %__MODULE__{type: :text, value: value}

  @spec object(map(), map() | nil) :: t()
  def object(value, schema \\ nil) when is_map(value),
    do: %__MODULE__{type: :object, value: value, schema: schema}

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{type: :map, value: value}), do: value
  def to_map(%__MODULE__{type: :text, value: value}), do: %{text: value}
  def to_map(%__MODULE__{type: :object, value: value}), do: %{object: value}

  @spec unwrap(t()) :: term()
  def unwrap(%__MODULE__{value: value}), do: value

  @spec mergeable?(t()) :: boolean()
  def mergeable?(%__MODULE__{type: :map}), do: true
  def mergeable?(%__MODULE__{}), do: false
end
