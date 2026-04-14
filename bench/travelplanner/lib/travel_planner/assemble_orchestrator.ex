defmodule TravelPlanner.AssembleOrchestrator do
  @moduledoc """
  Assemble stage orchestrator. The LLM synthesizes a day-by-day travel plan from
  the gather summary (passed as the query string) plus task constraints (ambient)
  and emits the final plan by calling `submit_plan` exactly once.

  No other tools are registered — `submit_plan` is the sole termination tool.
  Shape-validation errors from `submit_plan` are returned to the LLM so it can
  retry within `max_iterations`.
  """

  use Jido.Composer.Orchestrator,
    name: "travel_assemble",
    description: "Assembles a day-by-day travel plan from gathered reference data and submits via submit_plan.",
    model: "anthropic:claude-haiku-4-5-20251001",
    nodes: [],
    termination_tool: TravelPlanner.Tools.SubmitPlan,
    system_prompt: TravelPlanner.Prompts.assemble(),
    max_iterations: 8,
    temperature: 0.1,
    max_tokens: 4096,
    ambient: [:task]
end
