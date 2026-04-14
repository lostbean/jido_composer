defmodule TravelPlanner.GatherOrchestrator do
  @moduledoc """
  Gather stage orchestrator. Drives Claude Haiku 4.5 through the six
  TravelPlanner search tools until it has collected enough data for one task,
  then emits a concise markdown summary as the LLM's final text message.

  The ReferenceDB is injected via the ambient context under `:reference_db`
  (and the task under `:task`). Tools read it through `params[ambient_key()]`.
  """

  use Jido.Composer.Orchestrator,
    name: "travel_gather",
    description: "Gathers travel data via six search tools for one TravelPlanner task.",
    model: "anthropic:claude-haiku-4-5-20251001",
    nodes: [
      TravelPlanner.Tools.SearchFlights,
      TravelPlanner.Tools.SearchRestaurants,
      TravelPlanner.Tools.SearchAccommodations,
      TravelPlanner.Tools.SearchAttractions,
      TravelPlanner.Tools.GetDistance,
      TravelPlanner.Tools.SearchCities
    ],
    system_prompt: TravelPlanner.Prompts.gather(),
    max_iterations: 15,
    temperature: 0.2,
    max_tokens: 4096,
    ambient: [:reference_db, :task]
end
