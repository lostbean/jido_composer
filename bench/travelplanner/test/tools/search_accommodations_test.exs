defmodule TravelPlanner.Tools.SearchAccommodationsTest do
  use ExUnit.Case, async: true

  @moduletag :network

  alias Jido.Composer.Context
  alias TravelPlanner.Dataset
  alias TravelPlanner.ReferenceInfo
  alias TravelPlanner.Tools.SearchAccommodations

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
    test "returns accommodations for a known city", %{db: db} do
      params = ambient_params(db, %{city: "Myrtle Beach"})

      assert {:ok, %{accommodations: accommodations}} = SearchAccommodations.run(params, %{})
      assert is_list(accommodations)
      assert length(accommodations) > 0
      assert length(accommodations) <= 10

      first = hd(accommodations)
      assert Map.has_key?(first, :name)
      assert Map.has_key?(first, :city)
      assert Map.has_key?(first, :price)
      assert Map.has_key?(first, :room_type)
      assert Map.has_key?(first, :minimum_nights)
      assert Map.has_key?(first, :maximum_occupancy)
      assert Map.has_key?(first, :review_rate)
      assert Map.has_key?(first, :house_rules)
      assert is_list(first.house_rules)
    end

    test "returns an empty list for an unknown city", %{db: db} do
      params = ambient_params(db, %{city: "Nowhereville"})

      assert {:ok, %{accommodations: []}} = SearchAccommodations.run(params, %{})
    end

    test "raises when reference_db is missing from ambient context" do
      params = %{city: "Myrtle Beach"}

      assert_raise RuntimeError, ~r/missing reference_db/, fn ->
        SearchAccommodations.run(params, %{})
      end
    end
  end
end
