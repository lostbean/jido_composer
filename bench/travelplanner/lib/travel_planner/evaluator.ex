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

  Always runs all constraints (commonsense + hard) regardless of failures,
  so the full picture is available for parity testing and analysis.
  """
  @spec score_plan_detailed([map()], TravelPlanner.Task.t(), ReferenceDB.t()) :: %{
          passed: boolean(),
          commonsense: [{atom(), :ok | {:fail, String.t()}}],
          hard: [{atom(), :ok | {:fail, String.t()}}],
          commonsense_pass_rate: float(),
          hard_pass_rate: float(),
          total_pass_rate: float(),
          total_cost: number() | nil
        }
  def score_plan_detailed(plan, task, db) do
    commonsense_results = run_all_commonsense(plan, task, db)
    hard_results = run_all_hard(plan, task, db)

    cs_passed = Enum.count(commonsense_results, fn {_, r} -> r == :ok end)
    hard_passed = Enum.count(hard_results, fn {_, r} -> r == :ok end)
    total = length(commonsense_results) + length(hard_results)
    total_passed = cs_passed + hard_passed

    total_cost = compute_total_cost(plan, task, db)

    %{
      passed: cs_passed == length(commonsense_results) and hard_passed == length(hard_results),
      commonsense: commonsense_results,
      hard: hard_results,
      commonsense_pass_rate: cs_passed / length(commonsense_results),
      hard_pass_rate: hard_passed / length(hard_results),
      total_pass_rate: total_passed / total,
      total_cost: total_cost
    }
  end

  defp compute_total_cost(plan, task, db) do
    people = task.people_number || 1

    transport_cost =
      plan
      |> Enum.map(fn day ->
        entry = Map.get(day, "transportation", "-")
        unit_cost = TravelPlanner.Evaluator.Parse.parse_transport_cost(entry)

        if unit_cost do
          mode = TravelPlanner.Evaluator.Parse.detect_transport_mode(entry)

          case mode do
            :flight -> unit_cost * people
            :self_driving -> unit_cost * ceil_div(people, 5)
            :taxi -> unit_cost * ceil_div(people, 4)
            _ -> unit_cost * people
          end
        else
          0
        end
      end)
      |> Enum.sum()

    accommodation_cost =
      plan
      |> Enum.map(fn day ->
        entry = Map.get(day, "accommodation", "-")

        if entry == "-" do
          0
        else
          name = TravelPlanner.Evaluator.Parse.parse_accommodation_name(entry)
          city = TravelPlanner.Evaluator.Parse.parse_accommodation_city(entry)

          if city do
            accommodations = ReferenceDB.accommodations_in(db, city)

            case Enum.find(accommodations, &(&1.name == name)) do
              nil -> 0
              acc ->
                price = acc.price || 0
                max_occ = acc.maximum_occupancy || 1
                price * ceil_div(people, max_occ)
            end
          else
            0
          end
        end
      end)
      |> Enum.sum()

    restaurant_cost =
      plan
      |> Enum.flat_map(fn day ->
        Enum.map(["breakfast", "lunch", "dinner"], &Map.get(day, &1, "-"))
      end)
      |> Enum.reject(&(&1 == "-"))
      |> Enum.map(fn entry ->
        name = TravelPlanner.Evaluator.Parse.parse_restaurant_name(entry)
        city = TravelPlanner.Evaluator.Parse.parse_restaurant_city(entry)

        if city do
          restaurants = ReferenceDB.restaurants_in(db, city)

          case Enum.find(restaurants, &(&1.name == name)) do
            nil -> 0
            r -> r.average_cost || 0
          end
        else
          0
        end
      end)
      |> Enum.sum()

    transport_cost + accommodation_cost + restaurant_cost * people
  end

  defp ceil_div(a, b), do: div(a + b - 1, b)

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
