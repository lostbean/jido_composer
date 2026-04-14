defmodule TravelPlanner.Evaluator do
  @moduledoc """
  Top-level scoring function for the TravelPlanner benchmark.

  Runs all 13 constraints (8 commonsense + 5 hard) against a generated travel plan.
  Pure function of `(plan, task, reference_db)` — no LLM, no IO.
  """

  alias TravelPlanner.Evaluator.{Commonsense, Hard}
  alias TravelPlanner.ReferenceDB

  @type constraint_results :: %{
          commonsense: [:ok | {:fail, String.t()}],
          hard: [:ok | {:fail, String.t()}]
        }

  @doc """
  Score a generated plan against the task constraints.

  Runs all 8 commonsense constraints first. If any fail, returns immediately
  with the first failure. Only if all pass, runs the 5 hard constraints.

  Returns `{:pass, details}` if all 13 pass, or `{:fail, constraint_name, reason}`
  on the first failure.
  """
  @spec score_plan([map()], TravelPlanner.Task.t(), ReferenceDB.t()) ::
          {:pass, constraint_results()} | {:fail, atom(), String.t()}
  def score_plan(plan, task, db) do
    case Commonsense.check_all(plan, task, db) do
      :ok ->
        case Hard.check_all(plan, task, db) do
          :ok ->
            {:pass, %{commonsense: List.duplicate(:ok, 8), hard: List.duplicate(:ok, 5)}}

          {:fail, constraint, reason} ->
            {:fail, constraint, reason}
        end

      {:fail, constraint, reason} ->
        {:fail, constraint, reason}
    end
  end

  @doc """
  Score a plan and return a detailed report with all constraint results,
  not stopping at the first failure.
  """
  @spec score_plan_detailed([map()], TravelPlanner.Task.t(), ReferenceDB.t()) :: %{
          passed: boolean(),
          commonsense: [{atom(), :ok | {:fail, String.t()}}],
          hard: [{atom(), :ok | {:fail, String.t()}}],
          commonsense_pass_rate: float(),
          hard_pass_rate: float(),
          total_pass_rate: float()
        }
  def score_plan_detailed(plan, task, db) do
    commonsense_results = run_all_commonsense(plan, task, db)
    all_cs_pass = Enum.all?(commonsense_results, fn {_, r} -> r == :ok end)

    hard_results =
      if all_cs_pass do
        run_all_hard(plan, task, db)
      else
        hard_constraint_names()
        |> Enum.map(fn name -> {name, {:fail, "skipped (commonsense failed)"}} end)
      end

    cs_passed = Enum.count(commonsense_results, fn {_, r} -> r == :ok end)
    hard_passed = if all_cs_pass, do: Enum.count(hard_results, fn {_, r} -> r == :ok end), else: 0
    total = length(commonsense_results) + length(hard_results)
    total_passed = cs_passed + hard_passed

    %{
      passed: all_cs_pass and Enum.all?(hard_results, fn {_, r} -> r == :ok end),
      commonsense: commonsense_results,
      hard: hard_results,
      commonsense_pass_rate: cs_passed / length(commonsense_results),
      hard_pass_rate: if(all_cs_pass, do: hard_passed / length(hard_results), else: 0.0),
      total_pass_rate: total_passed / total
    }
  end

  defp commonsense_constraint_names do
    [
      :is_valid_plan_length,
      :is_reasonable_visiting_city,
      :is_valid_transportation,
      :is_valid_information_in_current_city,
      :is_valid_restaurants,
      :is_valid_attractions,
      :is_valid_accommodation,
      :is_not_absent
    ]
  end

  defp hard_constraint_names do
    [
      :is_valid_cuisine,
      :is_valid_room_rule,
      :is_valid_room_type,
      :is_valid_transportation_mode,
      :is_valid_cost
    ]
  end

  defp run_all_commonsense(plan, task, db) do
    Enum.map(commonsense_constraint_names(), fn name ->
      result = apply(Commonsense, name, [plan, task, db])
      {name, result}
    end)
  end

  defp run_all_hard(plan, task, db) do
    Enum.map(hard_constraint_names(), fn name ->
      result = apply(Hard, name, [plan, task, db])
      {name, result}
    end)
  end
end
