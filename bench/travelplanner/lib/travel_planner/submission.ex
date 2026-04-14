defmodule TravelPlanner.Submission do
  @moduledoc """
  Writes a JSONL submission file for the `osunlp/TravelPlannerLeaderboard` HF Space.

  Each line is a JSON object with `idx`, `query`, and `plan` keys.
  Failed tasks (nil plan) are written with an empty plan list.
  """

  @spec write(String.t(), [{TravelPlanner.Task.t(), [map()] | nil}]) :: :ok
  def write(output_path, results) do
    File.mkdir_p!(Path.dirname(output_path))

    lines =
      Enum.map(results, fn {task, plan} ->
        Jason.encode!(%{
          "idx" => task.idx,
          "query" => task.query,
          "plan" => plan || []
        })
      end)

    File.write!(output_path, Enum.join(lines, "\n") <> "\n")
  end
end
