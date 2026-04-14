defmodule TravelPlanner.Evaluator.Commonsense do
  @moduledoc """
  The 8 commonsense constraints for the TravelPlanner benchmark evaluator.

  Each function takes `(plan, task, db)` and returns `:ok` or `{:fail, reason}`.
  """

  alias TravelPlanner.Evaluator.Parse
  alias TravelPlanner.ReferenceDB

  @type result :: :ok | {:fail, String.t()}

  @constraints [
    :is_valid_plan_length,
    :is_reasonable_visiting_city,
    :is_valid_transportation,
    :is_valid_information_in_current_city,
    :is_valid_restaurants,
    :is_valid_attractions,
    :is_valid_accommodation,
    :is_not_absent
  ]

  @doc "Run all 8 commonsense constraints. Returns `:ok` or `{:fail, constraint_name, reason}`."
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

  @doc "Plan length must equal `task.days`."
  @spec is_valid_plan_length([map()], TravelPlanner.Task.t(), ReferenceDB.t()) :: result()
  def is_valid_plan_length(plan, task, _db) do
    if length(plan) == task.days do
      :ok
    else
      {:fail, "expected #{task.days} days, got #{length(plan)}"}
    end
  end

  @doc """
  The plan must form a closed round trip starting and ending at `task.org`.
  Every city visited must be `task.org` or one of the destination cities.
  """
  @spec is_reasonable_visiting_city([map()], TravelPlanner.Task.t(), ReferenceDB.t()) :: result()
  def is_reasonable_visiting_city(plan, task, db) do
    with :ok <- check_departure(plan, task),
         :ok <- check_return(plan, task),
         :ok <- check_all_cities_valid(plan, task, db) do
      :ok
    end
  end

  defp check_departure(plan, task) do
    first_day = List.first(plan)
    current_city = Map.get(first_day, "current_city", "")

    case Parse.parse_current_city(current_city) do
      {:travel, from, _to} ->
        if from == task.org, do: :ok, else: {:fail, "trip doesn't start at origin #{task.org}, starts at #{from}"}

      {:stay, city} ->
        if city == task.org, do: :ok, else: {:fail, "trip doesn't start at origin #{task.org}, starts at #{city}"}
    end
  end

  defp check_return(plan, task) do
    last_day = List.last(plan)
    current_city = Map.get(last_day, "current_city", "")

    case Parse.parse_current_city(current_city) do
      {:travel, _from, to} ->
        if to == task.org, do: :ok, else: {:fail, "trip doesn't end at origin #{task.org}, ends at #{to}"}

      {:stay, city} ->
        if city == task.org, do: :ok, else: {:fail, "trip doesn't end at origin #{task.org}, stays at #{city}"}
    end
  end

  defp check_all_cities_valid(plan, task, db) do
    allowed = allowed_cities(task, db)

    invalid =
      plan
      |> Enum.flat_map(fn day ->
        Parse.cities_for_day(Map.get(day, "current_city", ""))
      end)
      |> Enum.reject(&(&1 in allowed))
      |> Enum.uniq()

    if invalid == [] do
      :ok
    else
      {:fail, "plan visits cities not in task: #{inspect(invalid)}"}
    end
  end

  defp allowed_cities(task, db) do
    dest_cities =
      case task.dest do
        nil -> []
        dest -> String.split(dest, ~r/[,;]/) |> Enum.map(&String.trim/1)
      end

    db_cities = ReferenceDB.cities_with_data(db)

    ([task.org | dest_cities] ++ db_cities) |> Enum.uniq()
  end

  @doc """
  Transport consistency and reference DB validation.

  Flight and self-driving must not both appear as inter-city transport modes.
  Each transport entry must exist in the reference DB.
  """
  @spec is_valid_transportation([map()], TravelPlanner.Task.t(), ReferenceDB.t()) :: result()
  def is_valid_transportation(plan, _task, db) do
    transport_entries =
      plan
      |> Enum.map(&Map.get(&1, "transportation", "-"))
      |> Enum.reject(&(&1 == "-"))

    with :ok <- check_no_mixed_intercity_modes(transport_entries),
         :ok <- check_transport_exists_in_db(transport_entries, db) do
      :ok
    end
  end

  defp check_no_mixed_intercity_modes(entries) do
    modes =
      entries
      |> Enum.map(&Parse.detect_transport_mode/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    cond do
      :flight in modes and :self_driving in modes ->
        {:fail, "plan mixes flight and self-driving for inter-city transport"}

      :taxi in modes and :self_driving in modes ->
        {:fail, "plan mixes taxi and self-driving for inter-city transport"}

      true ->
        :ok
    end
  end

  defp check_transport_exists_in_db(entries, db) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case validate_single_transport(entry, db) do
        :ok -> {:cont, :ok}
        {:fail, _} = fail -> {:halt, fail}
      end
    end)
  end

  defp validate_single_transport(entry, db) do
    mode = Parse.detect_transport_mode(entry)

    case mode do
      :flight -> validate_flight_in_db(entry, db)
      :self_driving -> validate_ground_in_db(entry, db)
      :taxi -> validate_ground_in_db(entry, db)
      nil -> :ok
    end
  end

  defp validate_flight_in_db(entry, db) do
    flight_number = Parse.extract_flight_number(entry)

    if flight_number do
      all_flights =
        db.flights
        |> Map.values()
        |> List.flatten()

      if Enum.any?(all_flights, &(&1.flight_number == flight_number)) do
        :ok
      else
        {:fail, "flight #{flight_number} not found in reference DB"}
      end
    else
      {:fail, "could not extract flight number from: #{entry}"}
    end
  end

  defp validate_ground_in_db(entry, db) do
    case Parse.extract_ground_cities(entry) do
      {from, to} ->
        transport = ReferenceDB.ground_transport_for(db, from, to)
        mode = Parse.detect_transport_mode(entry)

        if Map.get(transport, mode) != nil do
          :ok
        else
          {:fail, "#{mode} from #{from} to #{to} not found in reference DB"}
        end

      nil ->
        # Be permissive — if we can't parse cities, don't fail
        :ok
    end
  end

  @doc """
  Every restaurant, attraction, and accommodation must exist in the reference DB
  for one of the cities in the day's `current_city`.
  """
  @spec is_valid_information_in_current_city([map()], TravelPlanner.Task.t(), ReferenceDB.t()) :: result()
  def is_valid_information_in_current_city(plan, _task, db) do
    Enum.reduce_while(plan, :ok, fn day, :ok ->
      cities = Parse.cities_for_day(Map.get(day, "current_city", ""))

      with :ok <- check_meals_in_cities(day, cities, db),
           :ok <- check_attractions_in_cities(day, cities, db),
           :ok <- check_accommodation_in_cities(day, cities, db) do
        {:cont, :ok}
      else
        {:fail, _} = fail -> {:halt, fail}
      end
    end)
  end

  defp check_meals_in_cities(day, cities, db) do
    meal_keys = ["breakfast", "lunch", "dinner"]

    Enum.reduce_while(meal_keys, :ok, fn key, :ok ->
      entry = Map.get(day, key, "-")

      if entry == "-" do
        {:cont, :ok}
      else
        name = Parse.parse_restaurant_name(entry)

        city_restaurants =
          cities
          |> Enum.flat_map(&ReferenceDB.restaurants_in(db, &1))
          |> Enum.map(& &1.name)

        if name in city_restaurants do
          {:cont, :ok}
        else
          {:halt, {:fail, "restaurant #{inspect(name)} not found in #{inspect(cities)}"}}
        end
      end
    end)
  end

  defp check_attractions_in_cities(day, cities, db) do
    attractions = Parse.parse_attractions(Map.get(day, "attraction", "-"))

    Enum.reduce_while(attractions, :ok, fn attr_name, :ok ->
      city_attractions =
        cities
        |> Enum.flat_map(&ReferenceDB.attractions_in(db, &1))
        |> Enum.map(& &1.name)

      if attr_name in city_attractions do
        {:cont, :ok}
      else
        {:halt, {:fail, "attraction #{inspect(attr_name)} not found in #{inspect(cities)}"}}
      end
    end)
  end

  defp check_accommodation_in_cities(day, cities, db) do
    entry = Map.get(day, "accommodation", "-")

    if entry == "-" do
      :ok
    else
      name = Parse.parse_accommodation_name(entry)

      city_accommodations =
        cities
        |> Enum.flat_map(&ReferenceDB.accommodations_in(db, &1))
        |> Enum.map(& &1.name)

      if name in city_accommodations do
        :ok
      else
        {:fail, "accommodation #{inspect(name)} not found in #{inspect(cities)}"}
      end
    end
  end

  @doc "No duplicate restaurant across the entire trip."
  @spec is_valid_restaurants([map()], TravelPlanner.Task.t(), ReferenceDB.t()) :: result()
  def is_valid_restaurants(plan, _task, _db) do
    all_names =
      plan
      |> Enum.flat_map(fn day ->
        ["breakfast", "lunch", "dinner"]
        |> Enum.map(&Map.get(day, &1, "-"))
        |> Enum.map(&Parse.parse_restaurant_name/1)
        |> Enum.reject(&is_nil/1)
      end)

    dupes = all_names -- Enum.uniq(all_names)

    if dupes == [] do
      :ok
    else
      {:fail, "duplicate restaurants: #{inspect(Enum.uniq(dupes))}"}
    end
  end

  @doc "No duplicate attraction across the entire trip."
  @spec is_valid_attractions([map()], TravelPlanner.Task.t(), ReferenceDB.t()) :: result()
  def is_valid_attractions(plan, _task, _db) do
    all_attractions =
      plan
      |> Enum.flat_map(fn day ->
        Parse.parse_attractions(Map.get(day, "attraction", "-"))
      end)

    dupes = all_attractions -- Enum.uniq(all_attractions)

    if dupes == [] do
      :ok
    else
      {:fail, "duplicate attractions: #{inspect(Enum.uniq(dupes))}"}
    end
  end

  @doc """
  Accommodation must be present for all days except possibly the last day.
  Also, consecutive nights at the same accommodation must satisfy its minimum_nights.
  """
  @spec is_valid_accommodation([map()], TravelPlanner.Task.t(), ReferenceDB.t()) :: result()
  def is_valid_accommodation(plan, _task, db) do
    with :ok <- check_no_missing_accommodation(plan),
         :ok <- check_minimum_nights(plan, db) do
      :ok
    end
  end

  defp check_no_missing_accommodation(plan) do
    # All days except the last must have accommodation
    non_last_days = Enum.slice(plan, 0..-2//1)

    missing =
      Enum.filter(non_last_days, fn day ->
        Map.get(day, "accommodation", "-") == "-"
      end)

    if missing == [] do
      :ok
    else
      day_nums = Enum.map(missing, &Map.get(&1, "days"))
      {:fail, "missing accommodation on days: #{inspect(day_nums)}"}
    end
  end

  defp check_minimum_nights(plan, db) do
    # Group consecutive nights at the same accommodation
    stays = extract_accommodation_stays(plan)

    Enum.reduce_while(stays, :ok, fn {name, city, nights}, :ok ->
      accommodations = ReferenceDB.accommodations_in(db, city)

      case Enum.find(accommodations, &(&1.name == name)) do
        nil ->
          # Can't validate minimum_nights if accommodation not found — skip
          {:cont, :ok}

        acc ->
          min = acc.minimum_nights || 1

          if nights >= min do
            {:cont, :ok}
          else
            {:halt, {:fail, "#{name} requires minimum #{min} nights, got #{nights}"}}
          end
      end
    end)
  end

  defp extract_accommodation_stays(plan) do
    plan
    |> Enum.map(fn day ->
      entry = Map.get(day, "accommodation", "-")

      if entry == "-" do
        nil
      else
        {Parse.parse_accommodation_name(entry), Parse.parse_accommodation_city(entry)}
      end
    end)
    |> Enum.chunk_by(& &1)
    |> Enum.reject(fn chunk -> List.first(chunk) == nil end)
    |> Enum.map(fn [{name, city} | _] = chunk -> {name, city, length(chunk)} end)
  end

  @doc """
  At least 50% of content slots should not be absent ("-").

  Content fields: breakfast, lunch, dinner, attraction, transportation, accommodation.
  """
  @spec is_not_absent([map()], TravelPlanner.Task.t(), ReferenceDB.t()) :: result()
  def is_not_absent(plan, _task, _db) do
    content_keys = ["breakfast", "lunch", "dinner", "attraction", "transportation", "accommodation"]

    {total, absent} =
      Enum.reduce(plan, {0, 0}, fn day, {total_acc, absent_acc} ->
        Enum.reduce(content_keys, {total_acc, absent_acc}, fn key, {t, a} ->
          val = Map.get(day, key, "-")
          {t + 1, if(val == "-", do: a + 1, else: a)}
        end)
      end)

    if total == 0 or absent / total <= 0.5 do
      :ok
    else
      {:fail, "too many absent entries: #{absent}/#{total} (#{Float.round(absent / total * 100, 1)}%)"}
    end
  end
end
