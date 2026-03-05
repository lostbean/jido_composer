defmodule Jido.Composer.Orchestrator.LLMAction do
  @moduledoc false
  # Internal action for executing LLM generate calls via RunInstruction.
  # Not intended for direct use — the Orchestrator Strategy creates
  # RunInstruction directives referencing this module.

  use Jido.Action,
    name: "orchestrator_llm_generate",
    description: "Internal: calls LLM generate/4",
    schema: []

  @impl true
  def run(params, _context) do
    llm_module = params[:llm_module]
    conversation = params[:conversation]
    tool_results = params[:tool_results] || []
    tools = params[:tools] || []
    opts = params[:opts] || []

    case llm_module.generate(conversation, tool_results, tools, opts) do
      {:ok, response, updated_conversation} ->
        {:ok, %{response: response, conversation: updated_conversation}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
