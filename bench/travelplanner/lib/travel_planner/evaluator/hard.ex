defmodule TravelPlanner.Evaluator.Hard do
  @moduledoc """
  The 5 hard constraints for the TravelPlanner benchmark evaluator.

  These are only checked after all 8 commonsense constraints pass.
  Each function takes `(plan, task, db)` and returns `:ok` or `{:fail, reason}`.
  """

  alias TravelPlanner.Evaluator.Parse
  alias TravelPlanner.ReferenceDB

  @type result :: :ok | {:fail, String.t()}

  @constraints [
    :is_valid_cuisine,
    :is_valid_room_rule,
    :is_valid_room_type,
    :is_valid_transportation_mode,
    :is_valid_cost
  ]

  @doc "Run all 5 hard constraints. Returns `:ok` or `{:fail, constraint_name, reason}`."
  @spec check_all([map()], TravelPlanner.Task.t(), ReferenceDB.t()) ::
          :ok | {:fail, atom(), String.t()}
  def check_all(plan, task, db) do
    Enum.reduce_while(@constraints, :ok, fn constraint, :ok ->
      case apply(__MODULE__, constraint, [plan, task, db]) do
        :ok -> {:cont, :ok}
        {:fail, reason} -> {:halt, {:fail, constraint, reason}}
      end
    end)
  end

  @doc """
  If `local_constraint` specifies a cuisine, at least one meal in the plan must
  serve that cuisine (checked against the restaurant's cuisines in the reference DB).
  """
  @spec is_valid_cuisine([map()], TravelPlanner.Task.t(), ReferenceDB.t()) :: result()
  def is_valid_cuisine(plan, task, db) do
    constraints = Parse.parse_local_constraint(task.local_constraint)

    case constraints.cuisine do
      nil ->
        :ok

      required_cuisine ->
        all_restaurants = collect_plan_restaurants(plan, db)

        has_cuisine =
          Enum.any?(all_restaurants, fn restaurant ->
            Enum.any?(restaurant.cuisines, fn c ->
              String.downcase(c) == String.downcase(required_cuisine)
            end)
          end)

        if has_cuisine do
          :ok
        else
          {:fail, "no restaurant serves required cuisine: #{required_cuisine}"}
        end
    end
  end

  @doc """
  If `local_constraint` specifies a house rule (e.g., "smoking"), all
  accommodations must NOT have the corresponding prohibition ("No smoking")
  in their house_rules list.
  """
  @spec is_valid_room_rule([map()], TravelPlanner.Task.t(), ReferenceDB.t()) :: result()
  def is_valid_room_rule(plan, task, db) do
    constraints = Parse.parse_local_constraint(task.local_constraint)

    case constraints.house_rule do
      nil ->
        :ok

      required_rule ->
        accommodations = collect_plan_accommodations(plan, db)
        prohibition = "no #{String.downcase(required_rule)}"

        violations =
          Enum.filter(accommodations, fn acc ->
            Enum.any?(acc.house_rules, fn rule ->
              String.downcase(rule) == prohibition
            end)
          end)

        if violations == [] do
          :ok
        else
          names = Enum.map(violations, & &1.name)
          {:fail, "accommodations #{inspect(names)} don't satisfy house rule: #{required_rule}"}
        end
    end
  end

  @room_type_map %{
    "entire room" => "Entire home/apt",
    "private room" => "Private room",
    "shared room" => "Shared room"
  }

  @doc """
  If `local_constraint` specifies a room type, all accommodations in the plan
  must match it. Handles negation (e.g., "not shared room").
  """
  @spec is_valid_room_type([map()], TravelPlanner.Task.t(), ReferenceDB.t()) :: result()
  def is_valid_room_type(plan, task, db) do
    constraints = Parse.parse_local_constraint(task.local_constraint)

    case constraints.room_type do
      nil ->
        :ok

      required_type ->
        accommodations = collect_plan_accommodations(plan, db)
        {negated, type_pattern} = parse_room_type_constraint(required_type)
        db_type = Map.get(@room_type_map, String.downcase(type_pattern), type_pattern)

        violations =
          Enum.reject(accommodations, fn acc ->
            matches = acc.room_type == db_type
            if negated, do: !matches, else: matches
          end)

        if violations == [] do
          :ok
        else
          names = Enum.map(violations, & &1.name)
          {:fail, "accommodations #{inspect(names)} don't match room type: #{required_type}"}
        end
    end
  end

  defp parse_room_type_constraint(constraint) do
    trimmed = String.trim(constraint)

    if String.starts_with?(String.downcase(trimmed), "not ") do
      {true, String.slice(trimmed, 4..-1//1) |> String.trim()}
    else
      {false, trimmed}
    end
  end

  @doc """
  If `local_constraint` specifies a transportation mode constraint
  (e.g., "no flight"), the plan must comply.
  """
  @spec is_valid_transportation_mode([map()], TravelPlanner.Task.t(), ReferenceDB.t()) :: result()
  def is_valid_transportation_mode(plan, task, _db) do
    constraints = Parse.parse_local_constraint(task.local_constraint)

    case constraints.transportation do
      nil ->
        :ok

      constraint_str ->
        transport_entries =
          plan
          |> Enum.map(&Map.get(&1, "transportation", "-"))
          |> Enum.reject(&(&1 == "-"))

        check_transport_constraint(transport_entries, constraint_str)
    end
  end

  defp check_transport_constraint(entries, constraint_str) do
    constraint_down = String.downcase(String.trim(constraint_str))

    cond do
      String.starts_with?(constraint_down, "no ") ->
        forbidden = String.slice(constraint_down, 3..-1//1) |> String.trim()
        check_no_transport(entries, forbidden, constraint_str)

      true ->
        # Positive constraint: must use this mode
        check_must_use_transport(entries, constraint_down, constraint_str)
    end
  end

  defp check_no_transport(entries, forbidden, original) do
    violation =
      Enum.find(entries, fn entry ->
        entry_down = String.downcase(entry)
        String.contains?(entry_down, forbidden)
      end)

    if violation do
      {:fail, "transport constraint '#{original}' violated by: #{violation}"}
    else
      :ok
    end
  end

  defp check_must_use_transport(entries, required, original) do
    has_required =
      Enum.any?(entries, fn entry ->
        entry_down = String.downcase(entry)
        String.contains?(entry_down, required)
      end)

    if has_required do
      :ok
    else
      {:fail, "transport constraint '#{original}' not satisfied — no matching transport found"}
    end
  end

  @doc """
  Total plan cost must not exceed `task.budget`.

  Sums: transport costs + accommodation nightly prices + restaurant average costs.
  Attractions are free. Cost is per-person multiplied by `task.people_number`.
  """
  @spec is_valid_cost([map()], TravelPlanner.Task.t(), ReferenceDB.t()) :: result()
  def is_valid_cost(plan, task, db) do
    budget = task.budget

    if budget == nil do
      :ok
    else
      people = task.people_number || 1
      transport_cost = sum_transport_costs(plan, db)
      accommodation_cost = sum_accommodation_costs(plan, db)
      restaurant_cost = sum_restaurant_costs(plan, db) * people
      total = transport_cost + accommodation_cost + restaurant_cost

      if total <= budget do
        :ok
      else
        {:fail, "total cost $#{total} exceeds budget $#{budget}" <>
          " (transport: $#{transport_cost}, accommodation: $#{accommodation_cost}," <>
          " meals: $#{restaurant_cost})"}
      end
    end
  end

  defp sum_transport_costs(plan, _db) do
    plan
    |> Enum.map(&Map.get(&1, "transportation", "-"))
    |> Enum.map(&Parse.parse_transport_cost/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sum()
  end

  defp sum_accommodation_costs(plan, db) do
    plan
    |> Enum.map(fn day ->
      entry = Map.get(day, "accommodation", "-")

      if entry == "-" do
        0
      else
        name = Parse.parse_accommodation_name(entry)
        city = Parse.parse_accommodation_city(entry)

        if city do
          accommodations = ReferenceDB.accommodations_in(db, city)

          case Enum.find(accommodations, &(&1.name == name)) do
            nil -> 0
            acc -> acc.price || 0
          end
        else
          0
        end
      end
    end)
    |> Enum.sum()
  end

  defp sum_restaurant_costs(plan, db) do
    meal_keys = ["breakfast", "lunch", "dinner"]

    plan
    |> Enum.flat_map(fn day ->
      Enum.map(meal_keys, &Map.get(day, &1, "-"))
    end)
    |> Enum.reject(&(&1 == "-"))
    |> Enum.map(fn entry ->
      name = Parse.parse_restaurant_name(entry)
      city = Parse.parse_restaurant_city(entry)

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
  end

  # Collect all restaurant structs from the plan that exist in the DB
  defp collect_plan_restaurants(plan, db) do
    meal_keys = ["breakfast", "lunch", "dinner"]

    plan
    |> Enum.flat_map(fn day ->
      Enum.map(meal_keys, &Map.get(day, &1, "-"))
    end)
    |> Enum.reject(&(&1 == "-"))
    |> Enum.flat_map(fn entry ->
      name = Parse.parse_restaurant_name(entry)
      city = Parse.parse_restaurant_city(entry)

      if city do
        restaurants = ReferenceDB.restaurants_in(db, city)
        Enum.filter(restaurants, &(&1.name == name))
      else
        []
      end
    end)
  end

  # Collect all accommodation structs from the plan that exist in the DB
  defp collect_plan_accommodations(plan, db) do
    plan
    |> Enum.map(fn day -> Map.get(day, "accommodation", "-") end)
    |> Enum.reject(&(&1 == "-"))
    |> Enum.uniq()
    |> Enum.flat_map(fn entry ->
      name = Parse.parse_accommodation_name(entry)
      city = Parse.parse_accommodation_city(entry)

      if city do
        accommodations = ReferenceDB.accommodations_in(db, city)
        Enum.filter(accommodations, &(&1.name == name))
      else
        []
      end
    end)
  end
end
