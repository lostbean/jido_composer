defmodule Jido.Composer.Workflow.DSLTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.TestActions.{AddAction, MultiplyAction}

  defmodule SimpleWorkflow do
    use Jido.Composer.Workflow,
      name: "simple_workflow",
      description: "A simple two-step workflow",
      nodes: %{
        extract: AddAction,
        transform: MultiplyAction
      },
      transitions: %{
        {:extract, :ok} => :transform,
        {:transform, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :extract
  end

  describe "module generation" do
    test "generates a module that can create an agent" do
      agent = SimpleWorkflow.new()
      assert agent.name == "simple_workflow"
    end

    test "agent has workflow strategy configured" do
      assert SimpleWorkflow.strategy() == Jido.Composer.Workflow.Strategy
    end

    test "strategy_opts contain node specs, transitions, and initial state" do
      opts = SimpleWorkflow.strategy_opts()
      assert is_map(opts[:nodes])
      assert is_map(opts[:transitions])
      assert opts[:initial] == :extract
    end
  end

  describe "node auto-wrapping" do
    test "bare action modules are tagged as {:action, Module}" do
      opts = SimpleWorkflow.strategy_opts()
      assert {:action, AddAction} = opts[:nodes][:extract]
      assert {:action, MultiplyAction} = opts[:nodes][:transform]
    end
  end

  describe "signal routes" do
    test "generated module declares workflow signal routes" do
      routes = SimpleWorkflow.signal_routes()
      route_types = Enum.map(routes, fn {type, _target} -> type end)
      assert "composer.workflow.start" in route_types
    end
  end

  describe "workflow execution" do
    test "run/2 starts the workflow with initial context" do
      agent = SimpleWorkflow.new()
      {agent, directives} = SimpleWorkflow.run(agent, %{value: 1.0, amount: 2.0})

      assert [%Jido.Agent.Directive.RunInstruction{}] = directives
      assert agent.state.__strategy__.machine.status == :extract
    end
  end
end
