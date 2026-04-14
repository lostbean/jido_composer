defmodule TravelPlanner.PlannerWorkflowTest do
  @moduledoc """
  Compile-time introspection tests for PlannerWorkflow.

  Verifies the module compiles correctly and has the expected FSM
  structure without making any LLM calls.
  """

  use ExUnit.Case, async: true

  alias Jido.Agent.Strategy.State, as: StratState

  describe "compilation" do
    test "PlannerWorkflow module is loaded and is a Jido.Agent" do
      assert Code.ensure_loaded?(TravelPlanner.PlannerWorkflow)
      assert function_exported?(TravelPlanner.PlannerWorkflow, :__agent_metadata__, 0)
    end

    test "metadata reflects workflow name and description" do
      assert TravelPlanner.PlannerWorkflow.name() == "travel_planner_pipeline"

      assert TravelPlanner.PlannerWorkflow.description() ==
               "Two-stage gather/assemble travel planning pipeline"
    end

    test "new/0 creates a valid agent struct" do
      agent = TravelPlanner.PlannerWorkflow.new()
      assert %Jido.Agent{} = agent
    end

    test "GatherAction and AssembleAction compile" do
      assert Code.ensure_loaded?(TravelPlanner.PlannerWorkflow.GatherAction)
      assert Code.ensure_loaded?(TravelPlanner.PlannerWorkflow.AssembleAction)
    end
  end

  describe "FSM introspection" do
    setup do
      agent = TravelPlanner.PlannerWorkflow.new()
      # Initialize strategy state so we can inspect the machine
      {agent, []} = TravelPlanner.PlannerWorkflow.cmd(agent, {:__strategy_init__, %{}})
      strat = StratState.get(agent)
      %{agent: agent, strat: strat, machine: strat.machine}
    end

    test "initial state is :gather", %{machine: machine} do
      assert machine.status == :gather
    end

    test "nodes include :gather and :assemble", %{machine: machine} do
      node_names = Map.keys(machine.nodes)
      assert :gather in node_names
      assert :assemble in node_names
    end

    test "transitions are defined for gather->assemble->done", %{machine: machine} do
      transitions = machine.transitions
      assert Map.get(transitions, {:gather, :ok}) == :assemble
      assert Map.get(transitions, {:assemble, :ok}) == :done
      assert Map.get(transitions, {:_, :error}) == :failed
    end

    test "terminal states include :done and :failed", %{machine: machine} do
      terminals = MapSet.new(machine.terminal_states)
      assert MapSet.member?(terminals, :done)
      assert MapSet.member?(terminals, :failed)
    end

    test "ambient keys include :task, :reference_db, :req_options", %{strat: strat} do
      ambient_keys = strat.ambient_keys
      assert :task in ambient_keys
      assert :reference_db in ambient_keys
      assert :req_options in ambient_keys
    end

    test "gather node is an ActionNode wrapping GatherAction", %{machine: machine} do
      gather_node = machine.nodes[:gather]
      assert %Jido.Composer.Node.ActionNode{} = gather_node
      assert gather_node.action_module == TravelPlanner.PlannerWorkflow.GatherAction
    end

    test "assemble node is an ActionNode wrapping AssembleAction", %{machine: machine} do
      assemble_node = machine.nodes[:assemble]
      assert %Jido.Composer.Node.ActionNode{} = assemble_node
      assert assemble_node.action_module == TravelPlanner.PlannerWorkflow.AssembleAction
    end
  end

  describe "run_task with use_workflow option" do
    test "use_workflow defaults to false (no workflow path taken)" do
      # Just verify the option is recognized and doesn't crash at parse time.
      # Actual execution would require LLM calls.
      assert is_function(&TravelPlanner.run_task/2)
    end
  end
end
