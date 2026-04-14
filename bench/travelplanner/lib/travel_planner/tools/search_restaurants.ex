defmodule TravelPlanner.Tools.SearchRestaurants do
  @moduledoc "Tool: list restaurants in a city."

  use Jido.Action,
    name: "search_restaurants",
    description: "List restaurants in a city. Returns up to 10 options.",
    schema: [
      city: [type: :string, required: true, doc: "City name, e.g. 'Rockford'"]
    ]

  alias Jido.Composer.Context
  alias TravelPlanner.ReferenceDB

  @impl true
  def run(%{city: city} = params, _ctx) do
    db = fetch_db!(params)

    restaurants =
      db
      |> ReferenceDB.restaurants_in(city)
      |> Enum.take(10)
      |> Enum.map(&restaurant_to_map/1)

    {:ok, %{restaurants: restaurants}}
  end

  defp fetch_db!(params) do
    ambient = Map.get(params, Context.ambient_key(), %{})

    case Map.get(ambient, :reference_db) do
      %ReferenceDB{} = db -> db
      _ -> raise "missing reference_db in ambient context"
    end
  end

  defp restaurant_to_map(%ReferenceDB.Restaurant{} = r) do
    %{
      name: r.name,
      city: r.city,
      cuisines: r.cuisines,
      average_cost: r.average_cost,
      aggregate_rating: r.aggregate_rating
    }
  end
end
