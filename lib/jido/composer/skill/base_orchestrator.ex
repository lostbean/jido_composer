defmodule Jido.Composer.Skill.BaseOrchestrator do
  @moduledoc false
  # Internal Orchestrator module used by Skill.assemble/2.
  # Provides a minimal base agent that can be configured with
  # dynamic prompts and tools at runtime.

  use Jido.Composer.Orchestrator,
    name: "skill_base_orchestrator",
    description: "Base orchestrator for skill assembly",
    nodes: [],
    system_prompt: ""
end
