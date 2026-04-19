defmodule TravelPlanner.Tools.SearchAttractions do
  @moduledoc "Tool: list tourist attractions in a city."

  use Jido.Action,
    name: "search_attractions",
    description: "List tourist attractions in a city. Returns up to 10 options.",
    schema: [
      city: [type: :string, required: true, doc: "City name, e.g. 'Rockford'"]
    ]

  alias Jido.Composer.Context
  alias TravelPlanner.ReferenceDB

  @impl true
  def run(%{city: city} = params, _ctx) do
    db = fetch_db!(params)

    attractions =
      db
      |> ReferenceDB.attractions_in(city)
      |> Enum.take(10)

    {:ok, %{attractions: attractions}}
  end

  defp fetch_db!(params) do
    ambient = Map.get(params, Context.ambient_key(), %{})

    case Map.get(ambient, :reference_db) do
      %ReferenceDB{} = db -> db
      _ -> raise "missing reference_db in ambient context"
    end
  end
end
