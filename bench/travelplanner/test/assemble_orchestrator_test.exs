defmodule TravelPlanner.AssembleOrchestratorTest do
  use ExUnit.Case, async: true

  alias Jido.Agent.Strategy.State, as: StratState
  alias TravelPlanner.AssembleOrchestrator
  alias TravelPlanner.Prompts
  alias TravelPlanner.Tools.SubmitPlan

  describe "compile-time wiring" do
    test "module compiles and exposes the generated orchestrator API" do
      Code.ensure_loaded!(AssembleOrchestrator)
      assert function_exported?(AssembleOrchestrator, :new, 1)
      assert function_exported?(AssembleOrchestrator, :query, 3)
      assert function_exported?(AssembleOrchestrator, :query_sync, 3)
      assert function_exported?(AssembleOrchestrator, :configure, 2)
      assert function_exported?(AssembleOrchestrator, :get_action_modules, 1)
      assert function_exported?(AssembleOrchestrator, :get_termination_module, 1)
    end
  end

  describe "strategy state introspection" do
    setup do
      {:ok, agent: AssembleOrchestrator.new()}
    end

    test "registers no action nodes (termination-only)", %{agent: agent} do
      assert AssembleOrchestrator.get_action_modules(agent) == []
    end

    test "registers SubmitPlan as the termination tool", %{agent: agent} do
      assert AssembleOrchestrator.get_termination_module(agent) == SubmitPlan
    end

    test "strategy state carries ambient keys, model, and LLM params", %{agent: agent} do
      state = StratState.get(agent, %{})

      assert state.ambient_keys == [:task]
      assert state.model == "anthropic:claude-haiku-4-5-20251001"
      assert state.max_iterations == 8
      assert state.temperature == 0.1
      assert state.max_tokens == 4096
      assert is_binary(state.system_prompt)
      assert state.system_prompt == Prompts.assemble()
    end
  end

  describe "Prompts.assemble/0" do
    test "returns a non-empty binary with assemble instructions" do
      prompt = Prompts.assemble()
      assert is_binary(prompt)
      assert prompt =~ "plan-assembly stage"
      assert prompt =~ "submit_plan"
    end
  end
end
