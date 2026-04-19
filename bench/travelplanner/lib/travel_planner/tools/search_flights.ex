defmodule TravelPlanner.Tools.SearchFlights do
  @moduledoc "Tool: find flights between two cities on a given date."

  use Jido.Action,
    name: "search_flights",
    description:
      "Find flights between an origin and destination city on a given date. Returns up to 10 options.",
    schema: [
      origin: [type: :string, required: true, doc: "Departure city, e.g. 'St. Petersburg'"],
      destination: [type: :string, required: true, doc: "Arrival city, e.g. 'Rockford'"],
      date: [type: :string, required: true, doc: "Date in YYYY-MM-DD format"]
    ]

  alias Jido.Composer.Context
  alias TravelPlanner.ReferenceDB

  @impl true
  def run(%{origin: origin, destination: destination, date: date} = params, _ctx) do
    db = fetch_db!(params)

    flights =
      db
      |> ReferenceDB.flights_for(origin, destination, date)
      |> Enum.take(10)

    {:ok, %{flights: flights}}
  end

  defp fetch_db!(params) do
    ambient = Map.get(params, Context.ambient_key(), %{})

    case Map.get(ambient, :reference_db) do
      %ReferenceDB{} = db -> db
      _ -> raise "missing reference_db in ambient context"
    end
  end
end
