defmodule Jido.Composer.Orchestrator.DSLTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.TestActions.{AddAction, EchoAction}
  alias Jido.Composer.TestSupport.MockLLM

  defmodule SimpleOrchestrator do
    use Jido.Composer.Orchestrator,
      name: "simple_orchestrator",
      description: "A simple orchestrator for testing",
      llm: Jido.Composer.TestSupport.MockLLM,
      nodes: [
        Jido.Composer.TestActions.AddAction,
        Jido.Composer.TestActions.EchoAction
      ],
      system_prompt: "You are a helpful test assistant.",
      max_iterations: 5
  end

  defmodule MinimalOrchestrator do
    use Jido.Composer.Orchestrator,
      name: "minimal_orchestrator",
      llm: Jido.Composer.TestSupport.MockLLM,
      nodes: [Jido.Composer.TestActions.AddAction]
  end

  describe "module generation" do
    test "generates a module that can create an agent" do
      agent = SimpleOrchestrator.new()
      assert agent.name == "simple_orchestrator"
    end

    test "agent has orchestrator strategy configured" do
      assert SimpleOrchestrator.strategy() == Jido.Composer.Orchestrator.Strategy
    end

    test "strategy_opts contain expected configuration" do
      opts = SimpleOrchestrator.strategy_opts()
      assert is_list(opts[:nodes])
      assert opts[:llm_module] == MockLLM
      assert opts[:system_prompt] == "You are a helpful test assistant."
      assert opts[:max_iterations] == 5
    end
  end

  describe "defaults" do
    test "description defaults when not provided" do
      agent = MinimalOrchestrator.new()
      assert agent.name == "minimal_orchestrator"
    end

    test "max_iterations defaults to 10 when not provided" do
      opts = MinimalOrchestrator.strategy_opts()
      assert opts[:max_iterations] == 10
    end

    test "system_prompt defaults to nil when not provided" do
      opts = MinimalOrchestrator.strategy_opts()
      assert opts[:system_prompt] == nil
    end

    test "req_options defaults to empty list" do
      opts = MinimalOrchestrator.strategy_opts()
      assert opts[:req_options] == []
    end
  end

  describe "node auto-wrapping" do
    test "bare action modules are included in strategy opts nodes list" do
      opts = SimpleOrchestrator.strategy_opts()
      assert AddAction in opts[:nodes]
      assert EchoAction in opts[:nodes]
    end
  end

  describe "signal routes" do
    test "generated module declares orchestrator signal routes" do
      routes = SimpleOrchestrator.signal_routes()
      route_types = Enum.map(routes, fn {type, _target} -> type end)
      assert "composer.orchestrator.query" in route_types
    end
  end

  describe "query/3" do
    test "sends orchestrator_start signal and returns directives" do
      MockLLM.setup([{:final_answer, "Test response"}])
      agent = SimpleOrchestrator.new()

      {agent, directives} = SimpleOrchestrator.query(agent, "Hello", %{})

      assert [%Jido.Agent.Directive.RunInstruction{}] = directives
      assert agent.state.__strategy__.status == :awaiting_llm
      assert agent.state.__strategy__.query == "Hello"
    end
  end
end
