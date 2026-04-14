defmodule TravelPlanner.Tools.SearchCities do
  @moduledoc "Tool: list cities that have reference data (restaurants/attractions/hotels) available."

  use Jido.Action,
    name: "search_cities",
    description:
      "List all cities that have reference data (restaurants, attractions, accommodations) " <>
        "available for this task. Use this to enumerate candidate destinations.",
    schema: []

  alias Jido.Composer.Context
  alias TravelPlanner.ReferenceDB

  @impl true
  def run(params, _ctx) do
    db = fetch_db!(params)
    {:ok, %{cities: ReferenceDB.cities_with_data(db)}}
  end

  defp fetch_db!(params) do
    ambient = Map.get(params, Context.ambient_key(), %{})

    case Map.get(ambient, :reference_db) do
      %ReferenceDB{} = db -> db
      _ -> raise "missing reference_db in ambient context"
    end
  end
end
