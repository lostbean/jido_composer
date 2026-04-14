defmodule TravelPlanner.ResultStore do
  @moduledoc """
  JSONL per-task writer and summary.json generator for benchmark runs.

  Writes one JSON line per task to `results.jsonl` (append mode), and a
  final `summary.json` once the run is complete.
  """

  @model "anthropic:claude-haiku-4-5-20251001"

  @doc """
  Ensure the output directory exists and return the paths for results files.
  """
  @spec init(String.t()) :: %{dir: String.t(), jsonl: String.t(), summary: String.t()}
  def init(output_dir) do
    File.mkdir_p!(output_dir)

    %{
      dir: output_dir,
      jsonl: Path.join(output_dir, "results.jsonl"),
      summary: Path.join(output_dir, "summary.json")
    }
  end

  @doc """
  Append a single task result to the JSONL file.

  Accepts a map with at least `:idx`, `:split`, `:status`, and `:elapsed_ms`.
  Depending on status, additional fields are expected:
    - `:pass` — `:plan`, `:constraint_details`
    - `:fail` — `:plan`, `:failed_constraint`, `:reason`
    - `:error` — `:stage`, `:reason`
  """
  @spec append_result(String.t(), map()) :: :ok
  def append_result(jsonl_path, result) when is_map(result) do
    line = Jason.encode!(result) <> "\n"
    File.write!(jsonl_path, line, [:append])
  end

  @doc """
  Build a pass result map.
  """
  @spec pass_result(non_neg_integer(), atom(), [map()], map(), non_neg_integer()) :: map()
  def pass_result(idx, split, plan, constraint_details, elapsed_ms) do
    %{
      idx: idx,
      split: to_string(split),
      status: "pass",
      plan: plan,
      constraint_details: constraint_details,
      elapsed_ms: elapsed_ms
    }
  end

  @doc """
  Build a fail result map.
  """
  @spec fail_result(non_neg_integer(), atom(), [map()], atom(), String.t(), non_neg_integer()) ::
          map()
  def fail_result(idx, split, plan, constraint, reason, elapsed_ms) do
    %{
      idx: idx,
      split: to_string(split),
      status: "fail",
      plan: plan,
      failed_constraint: to_string(constraint),
      reason: reason,
      elapsed_ms: elapsed_ms
    }
  end

  @doc """
  Build an error result map.
  """
  @spec error_result(non_neg_integer(), atom(), atom() | String.t(), String.t(), non_neg_integer()) ::
          map()
  def error_result(idx, split, stage, reason, elapsed_ms) do
    %{
      idx: idx,
      split: to_string(split),
      status: "error",
      stage: to_string(stage),
      reason: reason,
      elapsed_ms: elapsed_ms
    }
  end

  @doc """
  Write the summary.json file from accumulated results.
  """
  @spec write_summary(String.t(), atom(), [map()], non_neg_integer()) :: :ok
  def write_summary(summary_path, split, results, elapsed_total_ms) do
    total = length(results)
    pass_count = Enum.count(results, &(&1.status == "pass"))
    fail_count = Enum.count(results, &(&1.status == "fail"))
    error_count = Enum.count(results, &(&1.status == "error"))

    pass_rate = if total > 0, do: Float.round(pass_count / total, 4), else: 0.0

    per_constraint = build_per_constraint(results)

    summary = %{
      split: to_string(split),
      model: @model,
      total: total,
      pass: pass_count,
      fail: fail_count,
      error: error_count,
      pass_rate: pass_rate,
      per_constraint: per_constraint,
      elapsed_total_ms: elapsed_total_ms,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    json = Jason.encode!(summary, pretty: true)
    File.write!(summary_path, json)
  end

  defp build_per_constraint(results) do
    # Count per-constraint pass/fail from fail results
    fail_counts =
      results
      |> Enum.filter(&(&1.status == "fail"))
      |> Enum.frequencies_by(& &1.failed_constraint)

    scored = Enum.count(results, &(&1.status in ["pass", "fail"]))

    all_constraints = [
      "is_valid_plan_length",
      "is_reasonable_visiting_city",
      "is_valid_transportation",
      "is_valid_information_in_current_city",
      "is_valid_restaurants",
      "is_valid_attractions",
      "is_valid_accommodation",
      "is_not_absent",
      "is_valid_cuisine",
      "is_valid_room_rule",
      "is_valid_room_type",
      "is_valid_transportation_mode",
      "is_valid_cost"
    ]

    Map.new(all_constraints, fn name ->
      fails = Map.get(fail_counts, name, 0)
      {name, %{pass: scored - fails, fail: fails}}
    end)
  end
end
