defmodule TravelPlanner.Tools.SearchRestaurantsTest do
  use ExUnit.Case, async: true

  @moduletag :network

  alias Jido.Composer.Context
  alias TravelPlanner.Dataset
  alias TravelPlanner.ReferenceInfo
  alias TravelPlanner.Tools.SearchRestaurants

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
    test "returns restaurants for a known city", %{db: db} do
      params = ambient_params(db, %{city: "Myrtle Beach"})

      assert {:ok, %{restaurants: restaurants}} = SearchRestaurants.run(params, %{})
      assert is_list(restaurants)
      assert length(restaurants) > 0
      assert length(restaurants) <= 10

      first = hd(restaurants)
      assert Map.has_key?(first, :name)
      assert Map.has_key?(first, :city)
      assert Map.has_key?(first, :cuisines)
      assert Map.has_key?(first, :average_cost)
      assert Map.has_key?(first, :aggregate_rating)
      assert is_list(first.cuisines)
    end

    test "returns an empty list for an unknown city", %{db: db} do
      params = ambient_params(db, %{city: "Nowhereville"})

      assert {:ok, %{restaurants: []}} = SearchRestaurants.run(params, %{})
    end

    test "raises when reference_db is missing from ambient context" do
      params = %{city: "Myrtle Beach"}

      assert_raise RuntimeError, ~r/missing reference_db/, fn ->
        SearchRestaurants.run(params, %{})
      end
    end
  end
end
