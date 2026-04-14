defmodule TravelPlanner.Task do
  @moduledoc """
  A single TravelPlanner benchmark task as loaded from the HuggingFace dataset.

  Fields mirror the `osunlp/TravelPlanner` columns. Not all splits include all
  fields — the test split strips `local_constraint`, `people_number`, `budget`,
  and `annotated_plan` to prevent local scoring.
  """

  @enforce_keys [:idx, :split, :org, :dest, :days, :date, :level, :query, :reference_information]
  defstruct [
    :idx,
    :split,
    :org,
    :dest,
    :days,
    :date,
    :level,
    :query,
    :reference_information,
    :local_constraint,
    :people_number,
    :budget,
    :annotated_plan
  ]

  @type t :: %__MODULE__{
          idx: non_neg_integer(),
          split: :train | :validation | :test,
          org: String.t(),
          dest: String.t(),
          days: non_neg_integer(),
          date: [String.t()] | String.t() | nil,
          level: String.t(),
          query: String.t(),
          reference_information: String.t(),
          local_constraint: map() | nil,
          people_number: non_neg_integer() | nil,
          budget: number() | nil,
          annotated_plan: list(map()) | nil
        }
end
