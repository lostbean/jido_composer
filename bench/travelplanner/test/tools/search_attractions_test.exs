defmodule TravelPlanner.Tools.SearchAttractionsTest do
  use ExUnit.Case, async: true

  @moduletag :network

  alias Jido.Composer.Context
  alias TravelPlanner.Dataset
  alias TravelPlanner.ReferenceInfo
  alias TravelPlanner.Tools.SearchAttractions

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
    test "returns attractions for a known city", %{db: db} do
      params = ambient_params(db, %{city: "Myrtle Beach"})

      assert {:ok, %{attractions: attractions}} = SearchAttractions.run(params, %{})
      assert is_list(attractions)
      assert length(attractions) > 0
      assert length(attractions) <= 10

      first = hd(attractions)
      assert Map.has_key?(first, :name)
      assert Map.has_key?(first, :city)
      assert Map.has_key?(first, :address)
      assert Map.has_key?(first, :latitude)
      assert Map.has_key?(first, :longitude)
      assert Map.has_key?(first, :phone)
      assert Map.has_key?(first, :website)
    end

    test "returns an empty list for an unknown city", %{db: db} do
      params = ambient_params(db, %{city: "Nowhereville"})

      assert {:ok, %{attractions: []}} = SearchAttractions.run(params, %{})
    end

    test "raises when reference_db is missing from ambient context" do
      params = %{city: "Myrtle Beach"}

      assert_raise RuntimeError, ~r/missing reference_db/, fn ->
        SearchAttractions.run(params, %{})
      end
    end
  end
end
