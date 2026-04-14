defmodule TravelPlanner.Tools.GetDistance do
  @moduledoc "Tool: look up self-driving and taxi route info between two cities."

  use Jido.Action,
    name: "get_distance",
    description:
      "Get self-driving and taxi distance, duration, and cost between two cities. " <>
        "Either mode may be nil when not available.",
    schema: [
      origin: [type: :string, required: true, doc: "Origin city, e.g. 'St. Petersburg'"],
      destination: [type: :string, required: true, doc: "Destination city, e.g. 'Rockford'"]
    ]

  alias Jido.Composer.Context
  alias TravelPlanner.ReferenceDB

  @impl true
  def run(%{origin: origin, destination: destination} = params, _ctx) do
    db = fetch_db!(params)

    %{self_driving: self_driving, taxi: taxi} =
      ReferenceDB.ground_transport_for(db, origin, destination)

    {:ok,
     %{
       self_driving: to_map(self_driving),
       taxi: to_map(taxi)
     }}
  end

  defp fetch_db!(params) do
    ambient = Map.get(params, Context.ambient_key(), %{})

    case Map.get(ambient, :reference_db) do
      %ReferenceDB{} = db -> db
      _ -> raise "missing reference_db in ambient context"
    end
  end

  defp to_map(nil), do: nil

  defp to_map(%ReferenceDB.GroundTransport{} = g) do
    %{
      distance_km: g.distance_km,
      duration: g.duration,
      cost: g.cost
    }
  end
end
