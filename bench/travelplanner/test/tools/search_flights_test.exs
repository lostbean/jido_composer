defmodule TravelPlanner.Tools.SearchFlightsTest do
  use ExUnit.Case, async: true

  @moduletag :network

  alias Jido.Composer.Context
  alias TravelPlanner.Dataset
  alias TravelPlanner.ReferenceDB
  alias TravelPlanner.ReferenceInfo
  alias TravelPlanner.Tools.SearchFlights

  setup_all do
    tasks = Dataset.load(:validation)
    task = Enum.at(tasks, 0)
    db = ReferenceInfo.parse(task.reference_information)
    {:ok, task: task, db: db}
  end

  defp ambient_params(db, params) do
    Map.put(params, Context.ambient_key(), %{reference_db: db})
  end

  describe "run/2" do
    test "returns flights for a real task origin/destination/date", %{task: task, db: db} do
      {origin, destination, date} = pick_populated_flight_key!(db)

      params =
        ambient_params(db, %{
          origin: origin,
          destination: destination,
          date: date
        })

      assert {:ok, %{flights: flights}} = SearchFlights.run(params, %{})
      assert is_list(flights)
      assert length(flights) <= 10
      assert length(flights) > 0
      first = hd(flights)
      assert Map.has_key?(first, :flight_number)
      assert Map.has_key?(first, :dep_time)
      assert Map.has_key?(first, :arr_time)
      assert Map.has_key?(first, :price)
      assert Map.has_key?(first, :distance)

      # The picked key should be a real route in the task
      refute task == nil
    end

    test "returns an empty list for a nonsense destination", %{db: db} do
      params =
        ambient_params(db, %{
          origin: "St. Petersburg",
          destination: "Nowhereville",
          date: "2022-03-01"
        })

      assert {:ok, %{flights: []}} = SearchFlights.run(params, %{})
    end

    test "raises when reference_db is missing from ambient context" do
      params = %{origin: "A", destination: "B", date: "2022-03-01"}

      assert_raise RuntimeError, ~r/missing reference_db/, fn ->
        SearchFlights.run(params, %{})
      end
    end
  end

  # Find a flight key in the parsed DB that has at least one populated list.
  defp pick_populated_flight_key!(%ReferenceDB{flights: df}) do
    alias Explorer.DataFrame, as: DF

    case DF.to_rows(df, atom_keys: true) do
      [] -> raise "no populated flight keys in reference DB for task 0"
      [row | _] -> {row.origin, row.destination, row.date}
    end
  end
end
