defmodule TravelPlanner.Tools.SearchAccommodations do
  @moduledoc "Tool: list accommodations in a city."

  use Jido.Action,
    name: "search_accommodations",
    description: "List accommodations (hotels / short-term rentals) in a city. Returns up to 10 options.",
    schema: [
      city: [type: :string, required: true, doc: "City name, e.g. 'Rockford'"]
    ]

  alias Jido.Composer.Context
  alias TravelPlanner.ReferenceDB

  @impl true
  def run(%{city: city} = params, _ctx) do
    db = fetch_db!(params)

    accommodations =
      db
      |> ReferenceDB.accommodations_in(city)
      |> Enum.take(10)

    {:ok, %{accommodations: accommodations}}
  end

  defp fetch_db!(params) do
    ambient = Map.get(params, Context.ambient_key(), %{})

    case Map.get(ambient, :reference_db) do
      %ReferenceDB{} = db -> db
      _ -> raise "missing reference_db in ambient context"
    end
  end
end
