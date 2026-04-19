defmodule TravelPlanner.ReferenceInfoTest do
  use ExUnit.Case, async: true

  @moduletag :dataset

  alias Explorer.DataFrame, as: DF
  alias TravelPlanner.Dataset
  alias TravelPlanner.ReferenceDB
  alias TravelPlanner.ReferenceInfo

  setup_all do
    tasks = Dataset.load(:validation)
    task0 = Enum.at(tasks, 0)
    task179 = Enum.at(tasks, 179)
    db0 = ReferenceInfo.parse(task0.reference_information)
    db179 = ReferenceInfo.parse(task179.reference_information)
    {:ok, task0: task0, db0: db0, task179: task179, db179: db179}
  end

  describe "parse/1" do
    test "returns a ReferenceDB with populated DataFrames for idx 0", %{task0: task, db0: db} do
      assert %ReferenceDB{} = db
      assert DF.n_rows(db.flights) > 0
      assert DF.n_rows(db.accommodations) > 0
      assert DF.n_rows(db.attractions) > 0
      assert DF.n_rows(db.restaurants) > 0
      assert DF.n_rows(db.ground_transport) > 0

      # Every flight key we see should correspond to rows in the flights DataFrame.
      raw_flight_keys =
        task.reference_information
        |> Map.keys()
        |> Enum.filter(&String.starts_with?(&1, "Flight from "))

      # Each raw key maps to a unique origin/destination/date triple;
      # the DataFrame should have at least that many distinct triples.
      distinct_triples =
        db.flights
        |> DF.distinct([:origin, :destination, :date])
        |> DF.n_rows()

      assert length(raw_flight_keys) == distinct_triples
    end
  end

  describe "flights_for/4" do
    test "returns parsed flights matching raw records for idx 0", %{task0: task, db0: db} do
      raw_key =
        task.reference_information
        |> Map.keys()
        |> Enum.find(fn k ->
          String.starts_with?(k, "Flight from ") and is_list(Map.get(task.reference_information, k))
        end)

      assert raw_key, "expected idx 0 to have at least one populated flight key"

      [_, origin, destination, date] =
        Regex.run(~r/^Flight from (.+) to (.+) on (\d{4}-\d{2}-\d{2})$/, raw_key)

      raw_records = Map.get(task.reference_information, raw_key)
      flights = ReferenceDB.flights_for(db, origin, destination, date)

      assert length(flights) == length(raw_records)
      [first_raw | _] = raw_records
      [first_flight | _] = flights

      assert is_map(first_flight)
      assert first_flight.flight_number == first_raw["Flight Number"]
      assert first_flight.dep_time == first_raw["DepTime"]
      assert first_flight.arr_time == first_raw["ArrTime"]
      assert first_flight.price == first_raw["Price"]
      assert first_flight.distance == first_raw["Distance"]
      assert first_flight.duration == first_raw["ActualElapsedTime"]
      assert first_flight.origin == origin
      assert first_flight.destination == destination
      assert first_flight.date == date
    end

    test "returns [] for an unknown origin/destination/date", %{db0: db} do
      assert ReferenceDB.flights_for(db, "Atlantis", "Narnia", "2099-01-01") == []
    end

    test "returns [] when the raw value is a \"no flight\" string", %{task179: task, db179: db} do
      raw_key =
        task.reference_information
        |> Enum.find(fn {k, v} ->
          String.starts_with?(k, "Flight from ") and is_binary(v)
        end)

      assert raw_key, "expected idx 179 to have at least one no-flight string"
      {key, _value} = raw_key

      [_, origin, destination, date] =
        Regex.run(~r/^Flight from (.+) to (.+) on (\d{4}-\d{2}-\d{2})$/, key)

      # "No flight" entries should return an empty list from the query.
      assert ReferenceDB.flights_for(db, origin, destination, date) == []
    end
  end

  describe "accommodations_in/2" do
    test "parses house_rules into a list of strings", %{task0: task, db0: db} do
      city = task.dest
      accommodations = ReferenceDB.accommodations_in(db, city)
      refute accommodations == []

      Enum.each(accommodations, fn acc ->
        assert is_map(acc)
        assert is_list(acc.house_rules)
        assert Enum.all?(acc.house_rules, &is_binary/1)
      end)

      # Find a record whose raw house_rules uses " & " to confirm the split worked.
      raw_accs = Map.get(task.reference_information, "Accommodations in #{city}")

      joined =
        Enum.find(raw_accs, fn r ->
          rules = r["house_rules"]
          is_binary(rules) and String.contains?(rules, " & ")
        end)

      if joined do
        parsed =
          Enum.find(accommodations, fn a -> a.name == joined["NAME"] end)

        expected = String.split(joined["house_rules"], " & ") |> Enum.map(&String.trim/1)
        assert parsed.house_rules == expected
        assert length(parsed.house_rules) >= 2
      end
    end
  end

  describe "restaurants_in/2" do
    test "parses cuisines into a trimmed list of strings", %{task0: task, db0: db} do
      city = task.dest
      restaurants = ReferenceDB.restaurants_in(db, city)
      refute restaurants == []

      Enum.each(restaurants, fn r ->
        assert is_map(r)
        assert is_list(r.cuisines)
        assert Enum.all?(r.cuisines, &is_binary/1)
        # No leading/trailing whitespace.
        assert Enum.all?(r.cuisines, fn c -> c == String.trim(c) end)
      end)

      # Cross-check one against the raw record.
      raw_restaurants = Map.get(task.reference_information, "Restaurants in #{city}")
      multi = Enum.find(raw_restaurants, fn r -> String.contains?(r["Cuisines"] || "", ",") end)

      if multi do
        parsed = Enum.find(restaurants, fn r -> r.name == multi["Name"] end)
        expected = multi["Cuisines"] |> String.split(",") |> Enum.map(&String.trim/1)
        assert parsed.cuisines == expected
        assert length(parsed.cuisines) >= 2
      end
    end
  end

  describe "ground_transport_for/2" do
    test "parses distance as integer (stripping km) and cost as integer for idx 0",
         %{task0: task, db0: db} do
      ground = ReferenceDB.ground_transport_for(db, task.org, task.dest)

      assert %{mode: "self_driving"} = ground.self_driving
      assert %{mode: "taxi"} = ground.taxi

      assert is_integer(ground.self_driving.distance_km)
      assert ground.self_driving.distance_km > 0
      assert is_integer(ground.self_driving.cost)

      assert is_integer(ground.taxi.distance_km)
      assert ground.taxi.distance_km > 0
      assert is_integer(ground.taxi.cost)

      # They describe the same physical route so the distances should match.
      assert ground.self_driving.distance_km == ground.taxi.distance_km

      assert ground.self_driving.origin == task.org
      assert ground.self_driving.destination == task.dest
      assert is_binary(ground.self_driving.duration)
    end

    test "parses distances with thousand-separators for idx 179", %{db179: db} do
      # The raw value is "2,145 km" — make sure we strip the comma.
      ground = ReferenceDB.ground_transport_for(db, "Lubbock", "Reno")
      assert %{mode: "self_driving"} = ground.self_driving
      assert ground.self_driving.distance_km == 2145
    end

    test "returns the empty-arm map for unknown routes", %{db0: db} do
      assert ReferenceDB.ground_transport_for(db, "Nowhere", "Somewhere") == %{
               self_driving: nil,
               taxi: nil
             }
    end
  end

  describe "cities_with_data/1" do
    test "returns at least the destination city for idx 0", %{task0: task, db0: db} do
      cities = ReferenceDB.cities_with_data(db)
      assert is_list(cities)
      assert task.dest in cities
      # Sorted and unique
      assert cities == Enum.sort(Enum.uniq(cities))
    end

    test "returns all three destination cities for idx 179", %{db179: db} do
      cities = ReferenceDB.cities_with_data(db)
      assert "Abilene" in cities
      assert "Amarillo" in cities
      assert "Lubbock" in cities
    end
  end
end
