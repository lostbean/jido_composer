defmodule TravelPlanner.Tools.GetDistanceTest do
  use ExUnit.Case, async: true

  @moduletag :network

  alias Jido.Composer.Context
  alias TravelPlanner.Dataset
  alias TravelPlanner.ReferenceDB
  alias TravelPlanner.ReferenceInfo
  alias TravelPlanner.Tools.GetDistance

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
    test "returns distance info for a known route", %{db: db} do
      {origin, destination} = pick_populated_ground_key!(db)
      params = ambient_params(db, %{origin: origin, destination: destination})

      assert {:ok, result} = GetDistance.run(params, %{})
      assert Map.has_key?(result, :self_driving)
      assert Map.has_key?(result, :taxi)

      # At least one mode should be populated for a known route
      assert result.self_driving != nil or result.taxi != nil

      if result.self_driving do
        assert Map.has_key?(result.self_driving, :distance_km)
        assert Map.has_key?(result.self_driving, :duration)
        assert Map.has_key?(result.self_driving, :cost)
      end

      if result.taxi do
        assert Map.has_key?(result.taxi, :distance_km)
        assert Map.has_key?(result.taxi, :duration)
        assert Map.has_key?(result.taxi, :cost)
      end
    end

    test "returns nils for an unknown route", %{db: db} do
      params = ambient_params(db, %{origin: "Nowhereville", destination: "Ghosttown"})

      assert {:ok, %{self_driving: nil, taxi: nil}} = GetDistance.run(params, %{})
    end

    test "raises when reference_db is missing from ambient context" do
      params = %{origin: "A", destination: "B"}

      assert_raise RuntimeError, ~r/missing reference_db/, fn ->
        GetDistance.run(params, %{})
      end
    end
  end

  defp pick_populated_ground_key!(%ReferenceDB{ground_transport: df}) do
    alias Explorer.DataFrame, as: DF

    rows = DF.to_rows(df, atom_keys: true)

    case Enum.find(rows, fn row -> row.mode in ["self_driving", "taxi"] end) do
      nil -> raise "no populated ground transport keys in reference DB for task 0"
      row -> {row.origin, row.destination}
    end
  end
end
