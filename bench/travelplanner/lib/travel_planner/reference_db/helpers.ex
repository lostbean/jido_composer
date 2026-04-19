defmodule TravelPlanner.ReferenceDB.Helpers do
  @moduledoc """
  Utility functions for converting Explorer DataFrames to Elixir-friendly formats.
  """

  alias Explorer.DataFrame, as: DF

  @doc "Convert a DataFrame to a list of atom-keyed maps."
  @spec to_maps(DF.t()) :: [map()]
  def to_maps(df) do
    DF.to_rows(df, atom_keys: true)
  end

  @doc """
  Extract the first row of a DataFrame as an atom-keyed map, or nil if empty.
  """
  @spec to_map_or_nil(DF.t()) :: map() | nil
  def to_map_or_nil(df) do
    case DF.to_rows(df, atom_keys: true) do
      [row | _] -> row
      [] -> nil
    end
  end

  @doc """
  Split a pipe-separated string into a list.

  `"Seafood|Italian"` → `["Seafood", "Italian"]`
  `nil` → `[]`
  """
  @spec split_list_column(String.t() | nil) :: [String.t()]
  def split_list_column(nil), do: []
  def split_list_column(""), do: []
  def split_list_column(s) when is_binary(s), do: String.split(s, "|")
end
