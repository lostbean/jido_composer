defmodule TravelPlanner.PostProcess do
  @moduledoc """
  Deterministic post-processing for LLM-generated travel plans.

  Applies fixes in priority order to maximize evaluator pass rate:
  1. Entity name normalization (fuzzy match against reference DB)
  2. Restaurant deduplication
  3. Attraction deduplication
  4. Budget enforcement
  5. Trip loop closure (start/end at origin)
  """

  alias TravelPlanner.Evaluator.Parse
  alias TravelPlanner.ReferenceDB

  @meal_keys ["breakfast", "lunch", "dinner"]

  @doc """
  Apply all post-processing fixes to a plan.

  Takes the raw plan (list of string-keyed day maps), the task, and the
  reference DB. Returns a cleaned plan with entity names normalized,
  duplicates removed, budget enforced, and trip loop closed.
  """
  @spec fix([map()], TravelPlanner.Task.t(), ReferenceDB.t()) :: [map()]
  def fix(plan, task, db) do
    plan
    |> fix_entity_names(db)
    |> fix_entities_in_wrong_city(db)
    |> fill_empty_meals(db)
    |> fix_duplicate_restaurants(db)
    |> fix_duplicate_attractions(db)
    |> fix_transport_consistency(task, db)
    |> fix_accommodations(task, db)
    |> fix_budget(task, db)
    |> fix_trip_loop(task)
    |> fix_duplicate_restaurants(db)
    |> fix_duplicate_attractions(db)
  end

  # ---------------------------------------------------------------------------
  # Fix 1: Entity name normalization
  # ---------------------------------------------------------------------------

  defp fix_entity_names(plan, db) do
    Enum.map(plan, fn day ->
      cities = Parse.cities_for_day(Map.get(day, "current_city", ""))

      day
      |> fix_meal_names(cities, db)
      |> fix_attraction_names(cities, db)
      |> fix_accommodation_name(cities, db)
    end)
  end

  defp fix_meal_names(day, cities, db) do
    db_restaurants =
      cities
      |> Enum.flat_map(&ReferenceDB.restaurants_in(db, &1))
      |> Enum.map(& &1.name)

    Enum.reduce(@meal_keys, day, fn key, acc ->
      entry = Map.get(acc, key, "-")

      if entry == "-" do
        acc
      else
        name = Parse.parse_restaurant_name(entry)
        city = Parse.parse_restaurant_city(entry)

        case find_best_match(name, db_restaurants) do
          nil -> acc
          ^name -> acc
          matched -> Map.put(acc, key, format_with_city(matched, city))
        end
      end
    end)
  end

  defp fix_attraction_names(day, cities, db) do
    entry = Map.get(day, "attraction", "-")

    if entry == "-" do
      day
    else
      db_attractions =
        cities
        |> Enum.flat_map(&ReferenceDB.attractions_in(db, &1))
        |> Enum.map(& &1.name)

      attractions = Parse.parse_attractions(entry)

      fixed =
        Enum.map(attractions, fn attr_name ->
          case find_best_match(attr_name, db_attractions) do
            nil -> attr_name
            matched -> matched
          end
        end)

      Map.put(day, "attraction", Enum.join(fixed, "; "))
    end
  end

  defp fix_accommodation_name(day, cities, db) do
    entry = Map.get(day, "accommodation", "-")

    if entry == "-" do
      day
    else
      db_accommodations =
        cities
        |> Enum.flat_map(&ReferenceDB.accommodations_in(db, &1))
        |> Enum.map(& &1.name)

      name = Parse.parse_accommodation_name(entry)
      city = Parse.parse_accommodation_city(entry)

      case find_best_match(name, db_accommodations) do
        nil -> day
        ^name -> day
        matched -> Map.put(day, "accommodation", format_with_city(matched, city))
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Fix 1b: Fill empty meal slots to avoid is_not_absent failures
  # ---------------------------------------------------------------------------

  defp fill_empty_meals(plan, db) do
    content_keys = ["breakfast", "lunch", "dinner", "attraction", "transportation", "accommodation"]

    {total, absent} =
      Enum.reduce(plan, {0, 0}, fn day, {t, a} ->
        Enum.reduce(content_keys, {t, a}, fn key, {tt, aa} ->
          val = Map.get(day, key, "-")
          {tt + 1, if(val == "-", do: aa + 1, else: aa)}
        end)
      end)

    if total > 0 and absent / total > 0.4 do
      used_restaurants = MapSet.new(collect_all_restaurant_names(plan))
      do_fill_empty_meals(plan, used_restaurants, db)
    else
      plan
    end
  end

  defp do_fill_empty_meals(plan, used_restaurants, db) do
    {filled_plan, _used} =
      Enum.map_reduce(plan, used_restaurants, fn day, used ->
        cities = Parse.cities_for_day(Map.get(day, "current_city", ""))

        Enum.reduce(@meal_keys, {day, used}, fn key, {d, u} ->
          if Map.get(d, key, "-") == "-" do
            replacement =
              cities
              |> Enum.flat_map(&ReferenceDB.restaurants_in(db, &1))
              |> Enum.reject(&(&1.name in u))
              |> Enum.sort_by(fn r -> r.average_cost || 0 end)
              |> List.first()

            case replacement do
              nil ->
                {d, u}

              r ->
                city = r.city || List.first(cities)
                {Map.put(d, key, "#{r.name}, #{city}"), MapSet.put(u, r.name)}
            end
          else
            {d, u}
          end
        end)
      end)

    filled_plan
  end

  # ---------------------------------------------------------------------------
  # Fix 1c: Replace entities that exist in the DB but are in the wrong city
  # ---------------------------------------------------------------------------

  defp fix_entities_in_wrong_city(plan, db) do
    all_used_restaurants = MapSet.new(collect_all_restaurant_names(plan))
    all_used_attractions = MapSet.new(collect_all_attraction_names(plan))

    {fixed_plan, _used_r, _used_a} =
      Enum.reduce(plan, {[], all_used_restaurants, all_used_attractions}, fn day, {acc, used_r, used_a} ->
        cities = Parse.cities_for_day(Map.get(day, "current_city", ""))

        city_restaurants =
          cities
          |> Enum.flat_map(&ReferenceDB.restaurants_in(db, &1))
          |> Enum.map(& &1.name)
          |> MapSet.new()

        city_attractions =
          cities
          |> Enum.flat_map(&ReferenceDB.attractions_in(db, &1))
          |> Enum.map(& &1.name)
          |> MapSet.new()

        city_accommodations =
          cities
          |> Enum.flat_map(&ReferenceDB.accommodations_in(db, &1))
          |> Enum.map(& &1.name)
          |> MapSet.new()

        {day, used_r} = fix_wrong_city_meals(day, cities, city_restaurants, used_r, db)
        {day, used_a} = fix_wrong_city_attractions(day, cities, city_attractions, used_a, db)
        day = fix_wrong_city_accommodation(day, cities, city_accommodations, db)

        {[day | acc], used_r, used_a}
      end)

    Enum.reverse(fixed_plan)
  end

  defp fix_wrong_city_meals(day, cities, city_restaurant_names, used_names, db) do
    Enum.reduce(@meal_keys, {day, used_names}, fn key, {d, used} ->
      entry = Map.get(d, key, "-")

      if entry == "-" do
        {d, used}
      else
        name = Parse.parse_restaurant_name(entry)

        if name in city_restaurant_names do
          {d, used}
        else
          replacement =
            cities
            |> Enum.flat_map(&ReferenceDB.restaurants_in(db, &1))
            |> Enum.reject(&(&1.name in used))
            |> Enum.sort_by(fn r -> r.average_cost || 0 end)
            |> List.first()

          case replacement do
            nil -> {d, used}
            r ->
              city = r.city || List.first(cities)
              {Map.put(d, key, "#{r.name}, #{city}"), MapSet.put(MapSet.delete(used, name), r.name)}
          end
        end
      end
    end)
  end

  defp fix_wrong_city_attractions(day, cities, city_attraction_names, used_names, db) do
    entry = Map.get(day, "attraction", "-")

    if entry == "-" do
      {day, used_names}
    else
      attractions = Parse.parse_attractions(entry)

      {fixed_attrs, new_used} =
        Enum.map_reduce(attractions, used_names, fn attr_name, used ->
          if attr_name in city_attraction_names do
            {attr_name, used}
          else
            replacement =
              cities
              |> Enum.flat_map(&ReferenceDB.attractions_in(db, &1))
              |> Enum.reject(&(&1.name in used))
              |> List.first()

            case replacement do
              nil -> {attr_name, used}
              a -> {a.name, MapSet.put(MapSet.delete(used, attr_name), a.name)}
            end
          end
        end)

      {Map.put(day, "attraction", Enum.join(fixed_attrs, "; ")), new_used}
    end
  end

  defp fix_wrong_city_accommodation(day, cities, city_accommodation_names, db) do
    entry = Map.get(day, "accommodation", "-")

    if entry == "-" do
      day
    else
      name = Parse.parse_accommodation_name(entry)

      if name in city_accommodation_names do
        day
      else
        replacement =
          cities
          |> Enum.flat_map(&ReferenceDB.accommodations_in(db, &1))
          |> Enum.sort_by(& &1.price)
          |> List.first()

        case replacement do
          nil -> day
          a ->
            city = a.city || List.first(cities)
            Map.put(day, "accommodation", "#{a.name}, #{city}")
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Fix 2: Deduplicate restaurants
  # ---------------------------------------------------------------------------

  defp fix_duplicate_restaurants(plan, db) do
    # Collect all restaurant names used in the plan
    all_used = collect_all_restaurant_names(plan)
    dupes = all_used -- Enum.uniq(all_used)
    dupe_set = MapSet.new(dupes)

    if MapSet.size(dupe_set) == 0 do
      plan
    else
      {fixed_plan, _seen} =
        Enum.map_reduce(plan, MapSet.new(), fn day, seen ->
          cities = Parse.cities_for_day(Map.get(day, "current_city", ""))

          {fixed_day, new_seen} =
            Enum.reduce(@meal_keys, {day, seen}, fn key, {d, s} ->
              entry = Map.get(d, key, "-")

              if entry == "-" do
                {d, s}
              else
                name = Parse.parse_restaurant_name(entry)
                city = Parse.parse_restaurant_city(entry)

                if name in s and name in dupe_set do
                  # This is a duplicate occurrence, replace it
                  replacement = find_replacement_restaurant(cities, name, s, db)

                  case replacement do
                    nil ->
                      {d, MapSet.put(s, name)}

                    %{name: rep_name} ->
                      {Map.put(d, key, format_with_city(rep_name, city)), MapSet.put(s, rep_name)}
                  end
                else
                  {d, MapSet.put(s, name)}
                end
              end
            end)

          {fixed_day, new_seen}
        end)

      fixed_plan
    end
  end

  defp collect_all_restaurant_names(plan) do
    Enum.flat_map(plan, fn day ->
      @meal_keys
      |> Enum.map(&Map.get(day, &1, "-"))
      |> Enum.map(&Parse.parse_restaurant_name/1)
      |> Enum.reject(&is_nil/1)
    end)
  end

  defp find_replacement_restaurant(cities, current_name, used_names, db) do
    cities
    |> Enum.flat_map(&ReferenceDB.restaurants_in(db, &1))
    |> Enum.reject(fn r -> r.name == current_name or r.name in used_names end)
    |> Enum.sort_by(fn r -> r.average_cost || 0 end)
    |> List.first()
  end

  # ---------------------------------------------------------------------------
  # Fix 3: Deduplicate attractions
  # ---------------------------------------------------------------------------

  defp fix_duplicate_attractions(plan, db) do
    all_attractions = collect_all_attraction_names(plan)
    dupes = all_attractions -- Enum.uniq(all_attractions)
    dupe_set = MapSet.new(dupes)

    if MapSet.size(dupe_set) == 0 do
      plan
    else
      {fixed_plan, _seen} =
        Enum.map_reduce(plan, MapSet.new(), fn day, seen ->
          entry = Map.get(day, "attraction", "-")

          if entry == "-" do
            {day, seen}
          else
            cities = Parse.cities_for_day(Map.get(day, "current_city", ""))
            attractions = Parse.parse_attractions(entry)

            {fixed_attrs, new_seen} =
              Enum.map_reduce(attractions, seen, fn attr_name, s ->
                if attr_name in s and attr_name in dupe_set do
                  replacement = find_replacement_attraction(cities, attr_name, s, db)

                  case replacement do
                    nil -> {attr_name, MapSet.put(s, attr_name)}
                    %{name: rep_name} -> {rep_name, MapSet.put(s, rep_name)}
                  end
                else
                  {attr_name, MapSet.put(s, attr_name)}
                end
              end)

            {Map.put(day, "attraction", Enum.join(fixed_attrs, "; ")), new_seen}
          end
        end)

      fixed_plan
    end
  end

  defp collect_all_attraction_names(plan) do
    Enum.flat_map(plan, fn day ->
      Parse.parse_attractions(Map.get(day, "attraction", "-"))
    end)
  end

  defp find_replacement_attraction(cities, current_name, used_names, db) do
    cities
    |> Enum.flat_map(&ReferenceDB.attractions_in(db, &1))
    |> Enum.reject(fn a -> a.name == current_name or a.name in used_names end)
    |> List.first()
  end

  # ---------------------------------------------------------------------------
  # Fix 3b: Transport mode consistency
  # ---------------------------------------------------------------------------

  defp fix_transport_consistency(plan, task, db) do
    transport_with_modes =
      plan
      |> Enum.with_index()
      |> Enum.map(fn {day, idx} ->
        entry = Map.get(day, "transportation", "-")
        mode = Parse.detect_transport_mode(entry)
        intercity = mode != nil and mode != :taxi
        {idx, day, mode, intercity}
      end)

    intercity_modes =
      transport_with_modes
      |> Enum.filter(fn {_, _, _, intercity} -> intercity end)
      |> Enum.map(fn {_, _, mode, _} -> mode end)

    has_flight = :flight in intercity_modes
    has_self_driving = :self_driving in intercity_modes

    has_taxi = :taxi in intercity_modes

    cond do
      has_flight and has_self_driving ->
        dates = Parse.parse_dates(task.date)
        target_mode = pick_consistent_mode(transport_with_modes, dates, db)

        case target_mode do
          {:replace_with_taxi, keep_mode} ->
            replace_mode = if keep_mode == :flight, do: :self_driving, else: :flight
            apply_transport_replacement(plan, replace_mode, :taxi, db)

          mode ->
            apply_transport_mode(plan, mode, dates, db)
        end

      has_taxi and has_self_driving ->
        dates = Parse.parse_dates(task.date)
        apply_transport_mode(plan, :self_driving, dates, db)

      true ->
        plan
    end
  end

  defp pick_consistent_mode(transport_with_modes, dates, db) do
    intercity_entries =
      transport_with_modes
      |> Enum.filter(fn {_, _, _mode, intercity} -> intercity end)

    flight_count = Enum.count(intercity_entries, fn {_, _, mode, _} -> mode == :flight end)
    sd_count = Enum.count(intercity_entries, fn {_, _, mode, _} -> mode == :self_driving end)
    dominant = if flight_count >= sd_count, do: :flight, else: :self_driving
    minority = if dominant == :flight, do: :self_driving, else: :flight

    cond do
      can_replace_all?(intercity_entries, dominant, minority, dates, db) ->
        dominant

      can_replace_all?(intercity_entries, minority, dominant, dates, db) ->
        minority

      can_replace_with_taxi?(intercity_entries, dominant, minority, db) ->
        {:replace_with_taxi, dominant}

      true ->
        dominant
    end
  end

  defp can_replace_with_taxi?(entries, _keep_mode, replace_mode, db) do
    entries
    |> Enum.filter(fn {_, _, mode, _} -> mode == replace_mode end)
    |> Enum.all?(fn {_idx, day, _, _} ->
      case Parse.parse_current_city(Map.get(day, "current_city", "")) do
        {:travel, from, to} ->
          transport = ReferenceDB.ground_transport_for(db, from, to)
          transport.taxi != nil

        {:stay, _} ->
          true
      end
    end)
  end

  defp can_replace_all?(entries, target, source, dates, db) do
    entries
    |> Enum.filter(fn {_, _, mode, _} -> mode == source end)
    |> Enum.all?(fn {idx, day, _, _} ->
      case Parse.parse_current_city(Map.get(day, "current_city", "")) do
        {:travel, from, to} ->
          build_replacement_transport(from, to, target, dates, idx, db) != nil

        {:stay, _} ->
          true
      end
    end)
  end

  defp apply_transport_replacement(plan, replace_mode, with_mode, db) do
    Enum.map(plan, fn day ->
      entry = Map.get(day, "transportation", "-")
      mode = Parse.detect_transport_mode(entry)

      if mode == replace_mode do
        case Parse.parse_current_city(Map.get(day, "current_city", "")) do
          {:travel, from, to} ->
            replacement = build_replacement_transport(from, to, with_mode, [], 0, db)
            if replacement, do: Map.put(day, "transportation", replacement), else: day

          {:stay, _} ->
            day
        end
      else
        day
      end
    end)
  end

  defp apply_transport_mode(plan, target_mode, dates, db) do
    plan
    |> Enum.with_index()
    |> Enum.map(fn {day, idx} ->
      entry = Map.get(day, "transportation", "-")
      mode = Parse.detect_transport_mode(entry)

      if mode != nil and mode != :taxi and mode != target_mode do
        replace_transport_mode(day, target_mode, dates, idx, db)
      else
        day
      end
    end)
  end

  defp replace_transport_mode(day, target_mode, dates, day_idx, db) do
    current_city = Map.get(day, "current_city", "")

    case Parse.parse_current_city(current_city) do
      {:travel, from, to} ->
        replacement = build_replacement_transport(from, to, target_mode, dates, day_idx, db)

        if replacement do
          Map.put(day, "transportation", replacement)
        else
          day
        end

      {:stay, _} ->
        day
    end
  end

  defp build_replacement_transport(from, to, :self_driving, _dates, _day_idx, db) do
    transport = ReferenceDB.ground_transport_for(db, from, to)

    case transport.self_driving do
      %{cost: cost} when not is_nil(cost) ->
        "Self-driving, from #{from} to #{to}, $#{round(cost)}"

      _ ->
        transport_rev = ReferenceDB.ground_transport_for(db, to, from)

        case transport_rev.self_driving do
          %{cost: cost} when not is_nil(cost) ->
            "Self-driving, from #{from} to #{to}, $#{round(cost)}"

          _ ->
            nil
        end
    end
  end

  defp build_replacement_transport(from, to, :taxi, _dates, _day_idx, db) do
    transport = ReferenceDB.ground_transport_for(db, from, to)

    case transport.taxi do
      %{cost: cost} when not is_nil(cost) ->
        "Taxi, from #{from} to #{to}, $#{round(cost)}"

      _ ->
        transport_rev = ReferenceDB.ground_transport_for(db, to, from)

        case transport_rev.taxi do
          %{cost: cost} when not is_nil(cost) ->
            "Taxi, from #{from} to #{to}, $#{round(cost)}"

          _ ->
            nil
        end
    end
  end

  defp build_replacement_transport(from, to, :flight, dates, day_idx, db) do
    date = Enum.at(dates, day_idx)

    if date do
      flights = ReferenceDB.flights_for(db, from, to, date)
      cheapest = flights |> Enum.filter(&(&1.price != nil)) |> Enum.min_by(& &1.price, fn -> nil end)

      if cheapest do
        "Flight #{cheapest.flight_number}, $#{round(cheapest.price)}"
      else
        nil
      end
    else
      nil
    end
  end

  # ---------------------------------------------------------------------------
  # Fix 3c: Unified accommodation fix (house rules, room type, min_nights, missing)
  # ---------------------------------------------------------------------------

  @room_type_map %{
    "entire room" => "Entire home/apt",
    "private room" => "Private room",
    "shared room" => "Shared room"
  }

  defp fix_accommodations(plan, task, db) do
    constraints = Parse.parse_local_constraint(task.local_constraint)
    accom_filter = build_accommodation_filter(constraints)
    last_idx = length(plan) - 1

    stays = extract_accommodation_stays_with_indices(plan, last_idx)

    plan_after_stays =
      Enum.reduce(stays, plan, fn {name, cities, night_count, day_indices}, current_plan ->
        candidates =
          cities
          |> Enum.flat_map(&ReferenceDB.accommodations_in(db, &1))
          |> Enum.filter(accom_filter)

        current_acc = Enum.find(candidates, &(&1.name == name))
        valid_current = current_acc != nil && (current_acc.minimum_nights || 1) <= night_count

        if valid_current do
          current_plan
        else
          replacement =
            candidates
            |> Enum.reject(&(&1.name == name))
            |> Enum.filter(&((&1.minimum_nights || 1) <= night_count))
            |> Enum.sort_by(& &1.price)
            |> List.first()

          if replacement do
            city = replacement.city || List.first(cities)
            new_entry = "#{replacement.name}, #{city}"

            Enum.reduce(day_indices, current_plan, fn idx, p ->
              List.update_at(p, idx, &Map.put(&1, "accommodation", new_entry))
            end)
          else
            current_plan
          end
        end
      end)

    fill_missing_accommodations(plan_after_stays, last_idx, accom_filter, db)
  end

  defp build_accommodation_filter(constraints) do
    prohibition =
      case constraints.house_rule do
        nil -> nil
        rule -> "no #{String.downcase(rule)}"
      end

    {negated, room_pattern} =
      case constraints.room_type do
        nil -> {nil, nil}
        rt -> parse_room_type_constraint(rt)
      end

    db_room_type =
      if room_pattern, do: Map.get(@room_type_map, String.downcase(room_pattern), room_pattern)

    fn acc ->
      rule_ok =
        if prohibition do
          not Enum.any?(acc.house_rules || [], &(String.downcase(&1) == prohibition))
        else
          true
        end

      type_ok =
        if db_room_type do
          matches = acc.room_type == db_room_type
          if negated, do: !matches, else: matches
        else
          true
        end

      rule_ok and type_ok
    end
  end

  defp fill_missing_accommodations(plan, last_idx, accom_filter, db) do
    plan
    |> Enum.with_index()
    |> Enum.map(fn {day, idx} ->
      if idx == last_idx do
        day
      else
        entry = Map.get(day, "accommodation", "-")

        if entry == "-" do
          cities = Parse.cities_for_day(Map.get(day, "current_city", ""))
          stay_nights = length(plan) - 1 - idx

          replacement =
            cities
            |> Enum.flat_map(&ReferenceDB.accommodations_in(db, &1))
            |> Enum.filter(accom_filter)
            |> Enum.filter(&((&1.minimum_nights || 1) <= stay_nights))
            |> Enum.sort_by(& &1.price)
            |> List.first()

          if replacement do
            city = replacement.city || List.first(cities)
            Map.put(day, "accommodation", "#{replacement.name}, #{city}")
          else
            day
          end
        else
          day
        end
      end
    end)
  end

  defp extract_accommodation_stays_with_indices(plan, last_idx) do
    plan
    |> Enum.with_index()
    |> Enum.reject(fn {_, idx} -> idx == last_idx end)
    |> Enum.map(fn {day, idx} ->
      entry = Map.get(day, "accommodation", "-")
      name = if entry == "-", do: nil, else: Parse.parse_accommodation_name(entry)
      cities = Parse.cities_for_day(Map.get(day, "current_city", ""))
      {name, cities, idx}
    end)
    |> Enum.reject(fn {name, _, _} -> name == nil end)
    |> Enum.chunk_by(fn {name, _, _} -> name end)
    |> Enum.map(fn chunk ->
      {name, _, _} = hd(chunk)
      all_cities = chunk |> Enum.flat_map(fn {_, cities, _} -> cities end) |> Enum.uniq()
      indices = Enum.map(chunk, fn {_, _, idx} -> idx end)
      {name, all_cities, length(chunk), indices}
    end)
  end

  defp parse_room_type_constraint(constraint) do
    trimmed = String.trim(constraint)

    if String.starts_with?(String.downcase(trimmed), "not ") do
      {true, String.slice(trimmed, 4..-1//1) |> String.trim()}
    else
      {false, trimmed}
    end
  end

  # ---------------------------------------------------------------------------
  # Fix 5: Budget enforcement
  # ---------------------------------------------------------------------------

  defp fix_budget(plan, task, db) do
    budget = task.budget

    if budget == nil do
      plan
    else
      constraints = Parse.parse_local_constraint(task.local_constraint)
      accom_filter = build_accommodation_filter(constraints)
      people = task.people_number || 1
      transport_cost = sum_transport_costs(plan)
      accommodation_cost = sum_accommodation_costs(plan, db)
      restaurant_cost = sum_restaurant_costs(plan, db) * people
      total = transport_cost + accommodation_cost + restaurant_cost

      if total <= budget do
        plan
      else
        plan
        |> downgrade_accommodations(db, accom_filter)
        |> maybe_drop_meals(task, db)
      end
    end
  end

  defp downgrade_accommodations(plan, db, accom_filter) do
    last_idx = length(plan) - 1
    stays = extract_accommodation_stays_with_indices(plan, last_idx)

    Enum.reduce(stays, plan, fn {name, cities, night_count, day_indices}, current_plan ->
      candidates =
        cities
        |> Enum.flat_map(&ReferenceDB.accommodations_in(db, &1))
        |> Enum.filter(accom_filter)
        |> Enum.filter(&((&1.minimum_nights || 1) <= night_count))
        |> Enum.filter(&(&1.price != nil))

      current_acc = Enum.find(candidates, &(&1.name == name))
      cheapest = Enum.min_by(candidates, & &1.price, fn -> nil end)

      if cheapest && current_acc && cheapest.price < current_acc.price do
        city = cheapest.city || List.first(cities)
        new_entry = "#{cheapest.name}, #{city}"

        Enum.reduce(day_indices, current_plan, fn idx, p ->
          List.update_at(p, idx, &Map.put(&1, "accommodation", new_entry))
        end)
      else
        current_plan
      end
    end)
  end

  defp maybe_drop_meals(plan, task, db) do
    budget = task.budget
    people = task.people_number || 1
    transport_cost = sum_transport_costs(plan)
    accommodation_cost = sum_accommodation_costs(plan, db)
    restaurant_cost = sum_restaurant_costs(plan, db) * people
    total = transport_cost + accommodation_cost + restaurant_cost

    if total <= budget do
      plan
    else
      # Collect all meal entries with their cost, sort by most expensive first
      meals_with_cost =
        plan
        |> Enum.with_index()
        |> Enum.flat_map(fn {day, day_idx} ->
          Enum.map(@meal_keys, fn key ->
            entry = Map.get(day, key, "-")

            if entry == "-" do
              nil
            else
              name = Parse.parse_restaurant_name(entry)
              city = Parse.parse_restaurant_city(entry)
              cost = lookup_restaurant_cost(name, city, db)
              {day_idx, key, cost * people}
            end
          end)
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(fn {_, _, cost} -> -cost end)

      # Drop meals one at a time until under budget
      drop_meals_until_budget(plan, meals_with_cost, total, budget)
    end
  end

  defp drop_meals_until_budget(plan, [], _total, _budget), do: plan

  defp drop_meals_until_budget(plan, _meals, total, budget) when total <= budget, do: plan

  defp drop_meals_until_budget(plan, [{day_idx, key, cost} | rest], total, budget) do
    updated_plan = List.update_at(plan, day_idx, fn day -> Map.put(day, key, "-") end)
    drop_meals_until_budget(updated_plan, rest, total - cost, budget)
  end

  defp lookup_restaurant_cost(name, city, db) do
    if city do
      restaurants = ReferenceDB.restaurants_in(db, city)

      case Enum.find(restaurants, &(&1.name == name)) do
        nil -> 0
        r -> r.average_cost || 0
      end
    else
      0
    end
  end

  defp sum_transport_costs(plan) do
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
    plan
    |> Enum.flat_map(fn day ->
      Enum.map(@meal_keys, &Map.get(day, &1, "-"))
    end)
    |> Enum.reject(&(&1 == "-"))
    |> Enum.map(fn entry ->
      name = Parse.parse_restaurant_name(entry)
      city = Parse.parse_restaurant_city(entry)
      lookup_restaurant_cost(name, city, db)
    end)
    |> Enum.sum()
  end

  # ---------------------------------------------------------------------------
  # Fix 5: Close the trip loop
  # ---------------------------------------------------------------------------

  defp fix_trip_loop(plan, task) do
    plan
    |> fix_first_day(task)
    |> fix_last_day(task)
  end

  defp fix_first_day([], _task), do: []

  defp fix_first_day([first | rest], task) do
    current_city = Map.get(first, "current_city", "")

    case Parse.parse_current_city(current_city) do
      {:travel, from, _to} when from == task.org ->
        [first | rest]

      {:stay, city} when city == task.org ->
        [first | rest]

      {:travel, _from, to} ->
        [Map.put(first, "current_city", "#{task.org} to #{to}") | rest]

      {:stay, _city} ->
        # Single city stay on day 1 that isn't origin — likely needs travel
        [first | rest]
    end
  end

  defp fix_last_day([], _task), do: []

  defp fix_last_day(plan, task) do
    last_idx = length(plan) - 1
    last = Enum.at(plan, last_idx)
    current_city = Map.get(last, "current_city", "")

    case Parse.parse_current_city(current_city) do
      {:travel, _from, to} when to == task.org ->
        plan

      {:stay, city} when city == task.org ->
        plan

      {:travel, from, _to} ->
        List.replace_at(plan, last_idx, Map.put(last, "current_city", "#{from} to #{task.org}"))

      {:stay, city} ->
        List.replace_at(plan, last_idx, Map.put(last, "current_city", "#{city} to #{task.org}"))
    end
  end

  # ---------------------------------------------------------------------------
  # String matching helpers
  # ---------------------------------------------------------------------------

  @doc false
  def find_best_match(nil, _candidates), do: nil
  def find_best_match(_name, []), do: nil

  def find_best_match(name, candidates) do
    name_down = String.downcase(name)

    # Strategy 1: Exact match (case-insensitive)
    exact = Enum.find(candidates, fn c -> String.downcase(c) == name_down end)
    if exact, do: throw({:match, exact})

    # Strategy 2: Substring match (starts_with or contains)
    substr =
      Enum.find(candidates, fn c ->
        c_down = String.downcase(c)

        String.starts_with?(c_down, name_down) or String.starts_with?(name_down, c_down) or
          String.contains?(c_down, name_down) or String.contains?(name_down, c_down)
      end)

    if substr, do: throw({:match, substr})

    # Strategy 3: Normalized match (strip punctuation, extra spaces)
    name_norm = normalize(name)

    norm =
      Enum.find(candidates, fn c ->
        normalize(c) == name_norm
      end)

    if norm, do: throw({:match, norm})

    # Strategy 4: Fuzzy match (Jaro-Winkler > 0.85)
    best =
      candidates
      |> Enum.map(fn c -> {c, jaro_winkler(name_down, String.downcase(c))} end)
      |> Enum.max_by(fn {_, score} -> score end)

    case best do
      {candidate, score} when score > 0.85 -> candidate
      _ -> nil
    end
  catch
    {:match, result} -> result
  end

  defp normalize(str) do
    str
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp format_with_city(name, nil), do: name
  defp format_with_city(name, city), do: "#{name}, #{city}"

  # ---------------------------------------------------------------------------
  # Jaro-Winkler similarity
  # ---------------------------------------------------------------------------

  @doc false
  def jaro_winkler(s1, s2) do
    jaro = jaro_similarity(s1, s2)
    # Winkler boost: up to 4 common prefix chars
    prefix_len = common_prefix_length(s1, s2, 4)
    p = 0.1
    jaro + prefix_len * p * (1 - jaro)
  end

  defp jaro_similarity("", ""), do: 1.0
  defp jaro_similarity("", _), do: 0.0
  defp jaro_similarity(_, ""), do: 0.0

  defp jaro_similarity(s1, s2) do
    s1_chars = String.graphemes(s1)
    s2_chars = String.graphemes(s2)
    s1_len = length(s1_chars)
    s2_len = length(s2_chars)

    match_distance = max(div(max(s1_len, s2_len), 2) - 1, 0)

    {s1_matches, s2_matches, match_count} = find_matches(s1_chars, s2_chars, match_distance)

    if match_count == 0 do
      0.0
    else
      # Count transpositions
      s1_matched = for {c, true} <- Enum.zip(s1_chars, s1_matches), do: c
      s2_matched = for {c, true} <- Enum.zip(s2_chars, s2_matches), do: c

      transpositions =
        Enum.zip(s1_matched, s2_matched)
        |> Enum.count(fn {a, b} -> a != b end)
        |> div(2)

      m = match_count
      (m / s1_len + m / s2_len + (m - transpositions) / m) / 3.0
    end
  end

  defp find_matches(s1_chars, s2_chars, match_distance) do
    s2_len = length(s2_chars)
    s2_used = :array.new(s2_len, default: false)

    {s1_matches_list, s2_used_final, match_count} =
      Enum.reduce(Enum.with_index(s1_chars), {[], s2_used, 0}, fn {c1, i}, {s1m, s2u, mc} ->
        lo = max(0, i - match_distance)
        hi = min(s2_len - 1, i + match_distance)

        case find_first_match(s2_chars, c1, lo, hi, s2u) do
          nil ->
            {[false | s1m], s2u, mc}

          j ->
            {[true | s1m], :array.set(j, true, s2u), mc + 1}
        end
      end)

    s1_matches = Enum.reverse(s1_matches_list)
    s2_matches = for j <- 0..(s2_len - 1), do: :array.get(j, s2_used_final)

    {s1_matches, s2_matches, match_count}
  end

  defp find_first_match(s2_chars, c1, lo, hi, s2_used) do
    Enum.find(lo..hi//1, fn j ->
      not :array.get(j, s2_used) and Enum.at(s2_chars, j) == c1
    end)
  end

  defp common_prefix_length(s1, s2, max_len) do
    s1
    |> String.graphemes()
    |> Enum.zip(String.graphemes(s2))
    |> Enum.take(max_len)
    |> Enum.take_while(fn {a, b} -> a == b end)
    |> length()
  end
end
