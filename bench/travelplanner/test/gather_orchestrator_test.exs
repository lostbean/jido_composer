defmodule TravelPlanner.GatherOrchestratorTest do
  use ExUnit.Case, async: true

  alias Jido.Agent.Strategy.State, as: StratState
  alias TravelPlanner.GatherOrchestrator
  alias TravelPlanner.Prompts

  @expected_tools [
    TravelPlanner.Tools.SearchFlights,
    TravelPlanner.Tools.SearchRestaurants,
    TravelPlanner.Tools.SearchAccommodations,
    TravelPlanner.Tools.SearchAttractions,
    TravelPlanner.Tools.GetDistance,
    TravelPlanner.Tools.SearchCities
  ]

  describe "compile-time wiring" do
    test "module compiles and exposes the generated orchestrator API" do
      Code.ensure_loaded!(GatherOrchestrator)
      assert function_exported?(GatherOrchestrator, :new, 1)
      assert function_exported?(GatherOrchestrator, :query, 3)
      assert function_exported?(GatherOrchestrator, :query_sync, 3)
      assert function_exported?(GatherOrchestrator, :configure, 2)
      assert function_exported?(GatherOrchestrator, :get_action_modules, 1)
      assert function_exported?(GatherOrchestrator, :get_termination_module, 1)
    end
  end

  describe "strategy state introspection" do
    setup do
      {:ok, agent: GatherOrchestrator.new()}
    end

    test "registers all six search tools as node modules", %{agent: agent} do
      modules = GatherOrchestrator.get_action_modules(agent)
      assert Enum.sort(modules) == Enum.sort(@expected_tools)
    end

    test "no termination tool is configured (free-form final answer)", %{agent: agent} do
      assert GatherOrchestrator.get_termination_module(agent) == nil
    end

    test "strategy state carries ambient keys, model, and LLM params", %{agent: agent} do
      state = StratState.get(agent, %{})

      assert state.ambient_keys == [:reference_db, :task]
      assert state.model == "anthropic:claude-haiku-4-5-20251001"
      assert state.max_iterations == 15
      assert state.temperature == 0.2
      assert state.max_tokens == 4096
      assert is_binary(state.system_prompt)
      assert state.system_prompt == Prompts.gather()
      assert length(state.tools) == 6
    end
  end

  describe "Prompts" do
    test "gather/0 returns a non-empty binary with the gather instructions" do
      prompt = Prompts.gather()
      assert is_binary(prompt)
      assert prompt =~ "information-gathering stage"
      assert prompt =~ "six tools"
    end

    test "assemble/0 returns the M5 assemble prompt" do
      assert Prompts.assemble() =~ "plan-assembly stage"
    end
  end
end
