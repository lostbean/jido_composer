defmodule TravelPlanner.Tools.SearchCitiesTest do
  use ExUnit.Case, async: true

  @moduletag :network

  alias Jido.Composer.Context
  alias TravelPlanner.Dataset
  alias TravelPlanner.ReferenceInfo
  alias TravelPlanner.Tools.SearchCities

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
    test "returns a sorted list of cities with data", %{db: db} do
      params = ambient_params(db, %{})

      assert {:ok, %{cities: cities}} = SearchCities.run(params, %{})
      assert is_list(cities)
      assert length(cities) > 0
      assert cities == Enum.sort(cities)

      # Task 0 destination is Myrtle Beach — it should appear in the city list
      assert "Myrtle Beach" in cities
    end

    test "raises when reference_db is missing from ambient context" do
      params = %{}

      assert_raise RuntimeError, ~r/missing reference_db/, fn ->
        SearchCities.run(params, %{})
      end
    end
  end
end
