defmodule TravelPlanner.ReferenceDBTest do
  use ExUnit.Case, async: true

  @moduletag :network

  alias TravelPlanner.Dataset
  alias TravelPlanner.ReferenceDB
  alias TravelPlanner.ReferenceInfo

  setup_all do
    tasks = Dataset.load(:validation)
    task = Enum.at(tasks, 0)
    db = ReferenceInfo.parse(task.reference_information)
    {:ok, task: task, db: db}
  end

  describe "flights_for/4" do
    test "returns flights for a valid key", %{db: db} do
      {origin, destination, date} = pick_populated_flight_key!(db)

      flights = ReferenceDB.flights_for(db, origin, destination, date)
      assert is_list(flights)
      assert length(flights) > 0
      first = hd(flights)
      assert %ReferenceDB.Flight{} = first
      assert first.origin == origin
      assert first.destination == destination
    end

    test "returns empty list for unknown key", %{db: db} do
      assert [] == ReferenceDB.flights_for(db, "Nowhereville", "Ghosttown", "2099-01-01")
    end
  end

  describe "ground_transport_for/3" do
    test "returns self_driving/taxi map for a known route", %{db: db} do
      {origin, destination} = pick_populated_ground_key!(db)

      result = ReferenceDB.ground_transport_for(db, origin, destination)
      assert is_map(result)
      assert Map.has_key?(result, :self_driving)
      assert Map.has_key?(result, :taxi)

      # At least one mode should be populated
      assert result.self_driving != nil or result.taxi != nil

      if result.self_driving do
        assert %ReferenceDB.GroundTransport{mode: :self_driving} = result.self_driving
      end

      if result.taxi do
        assert %ReferenceDB.GroundTransport{mode: :taxi} = result.taxi
      end
    end

    test "returns nils for unknown route", %{db: db} do
      assert %{self_driving: nil, taxi: nil} =
               ReferenceDB.ground_transport_for(db, "Nowhereville", "Ghosttown")
    end
  end

  describe "restaurants_in/2" do
    test "returns list for known city", %{db: db} do
      restaurants = ReferenceDB.restaurants_in(db, "Myrtle Beach")
      assert is_list(restaurants)
      assert length(restaurants) > 0
      first = hd(restaurants)
      assert %ReferenceDB.Restaurant{} = first
      assert first.city == "Myrtle Beach"
      assert is_list(first.cuisines)
    end

    test "returns empty list for unknown city", %{db: db} do
      assert [] == ReferenceDB.restaurants_in(db, "Nowhereville")
    end
  end

  describe "accommodations_in/2" do
    test "returns list with correct struct fields", %{db: db} do
      accommodations = ReferenceDB.accommodations_in(db, "Myrtle Beach")
      assert is_list(accommodations)
      assert length(accommodations) > 0
      first = hd(accommodations)
      assert %ReferenceDB.Accommodation{} = first
      assert first.city == "Myrtle Beach"
      assert is_list(first.house_rules)
    end

    test "returns empty list for unknown city", %{db: db} do
      assert [] == ReferenceDB.accommodations_in(db, "Nowhereville")
    end
  end

  describe "attractions_in/2" do
    test "returns list for known city", %{db: db} do
      attractions = ReferenceDB.attractions_in(db, "Myrtle Beach")
      assert is_list(attractions)
      assert length(attractions) > 0
      first = hd(attractions)
      assert %ReferenceDB.Attraction{} = first
      assert first.city == "Myrtle Beach"
    end

    test "returns empty list for unknown city", %{db: db} do
      assert [] == ReferenceDB.attractions_in(db, "Nowhereville")
    end
  end

  describe "cities_with_data/1" do
    test "returns sorted unique city names", %{db: db} do
      cities = ReferenceDB.cities_with_data(db)
      assert is_list(cities)
      assert length(cities) > 0
      assert cities == Enum.sort(cities)
      assert cities == Enum.uniq(cities)

      # Task 0 destination is Myrtle Beach
      assert "Myrtle Beach" in cities
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp pick_populated_flight_key!(%ReferenceDB{flights: flights}) do
    {{origin, destination, date}, _list} =
      flights
      |> Enum.find(fn {_key, list} -> is_list(list) and list != [] end)
      |> case do
        nil -> raise "no populated flight keys in reference DB for task 0"
        other -> other
      end

    {origin, destination, date}
  end

  defp pick_populated_ground_key!(%ReferenceDB{ground_transport: ground}) do
    {{origin, destination}, _modes} =
      ground
      |> Enum.find(fn {_key, modes} ->
        modes.self_driving != nil or modes.taxi != nil
      end)
      |> case do
        nil -> raise "no populated ground transport keys in reference DB for task 0"
        other -> other
      end

    {origin, destination}
  end
end
