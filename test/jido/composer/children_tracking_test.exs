defmodule Jido.Composer.ChildrenTrackingTest do
  use ExUnit.Case, async: true

  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.Composer.ChildRef

  # -- Test workflow that uses AgentNode --

  alias Jido.Composer.TestActions.NoopAction

  defmodule ChildTrackingWorkflow do
    use Jido.Composer.Workflow,
      name: "child_tracking_workflow",
      description: "Workflow for child tracking tests",
      nodes: %{
        process: NoopAction,
        finish: NoopAction
      },
      transitions: %{
        {:process, :ok} => :finish,
        {:finish, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :process
  end

  describe "workflow child_started populates children map" do
    test "child_started adds ChildRef with :running status" do
      agent = ChildTrackingWorkflow.new()
      {agent, _directives} = ChildTrackingWorkflow.run(agent, %{tag: "test"})

      # Simulate child_started signal
      {agent, _directives} =
        ChildTrackingWorkflow.cmd(
          agent,
          {:workflow_child_started,
           %{
             tag: :process,
             agent_module: SomeChildModule,
             agent_id: "child-001"
           }}
        )

      strat = StratState.get(agent)
      assert %ChildRef{} = ref = strat.children[:process]
      assert ref.agent_module == SomeChildModule
      assert ref.agent_id == "child-001"
      assert ref.tag == :process
      assert ref.status == :running
    end
  end

  describe "workflow child_exit updates children map" do
    test "child_exit with normal reason sets :completed" do
      agent = ChildTrackingWorkflow.new()
      {agent, _directives} = ChildTrackingWorkflow.run(agent, %{tag: "test"})

      # Add child first
      {agent, _} =
        ChildTrackingWorkflow.cmd(
          agent,
          {:workflow_child_started,
           %{
             tag: :process,
             agent_module: SomeChildModule,
             agent_id: "child-001"
           }}
        )

      # Simulate child exit
      {agent, _} =
        ChildTrackingWorkflow.cmd(
          agent,
          {:workflow_child_exit,
           %{
             tag: :process,
             reason: :normal
           }}
        )

      strat = StratState.get(agent)
      assert strat.children[:process].status == :completed
    end

    test "child_exit with non-normal reason sets :failed" do
      agent = ChildTrackingWorkflow.new()
      {agent, _directives} = ChildTrackingWorkflow.run(agent, %{tag: "test"})

      {agent, _} =
        ChildTrackingWorkflow.cmd(
          agent,
          {:workflow_child_started,
           %{
             tag: :worker,
             agent_module: SomeChildModule,
             agent_id: "child-002"
           }}
        )

      {agent, _} =
        ChildTrackingWorkflow.cmd(
          agent,
          {:workflow_child_exit,
           %{
             tag: :worker,
             reason: {:error, :crashed}
           }}
        )

      strat = StratState.get(agent)
      assert strat.children[:worker].status == :failed
    end
  end

  describe "orchestrator child_started populates children map" do
    alias Jido.Composer.TestActions.NoopAction

    defmodule ChildTrackingOrchestrator do
      use Jido.Composer.Orchestrator,
        name: "child_tracking_orch",
        description: "Orchestrator for child tracking tests",
        model: "test-model",
        system_prompt: "test",
        nodes: [NoopAction]
    end

    test "child_started adds ChildRef with :running status" do
      agent = ChildTrackingOrchestrator.new()
      {agent, _directives} = ChildTrackingOrchestrator.query(agent, "test")

      {agent, _directives} =
        ChildTrackingOrchestrator.cmd(
          agent,
          {:orchestrator_child_started,
           %{
             tag: :worker,
             agent_module: SomeChildModule,
             agent_id: "orch-child-001"
           }}
        )

      strat = StratState.get(agent)
      assert %ChildRef{} = ref = strat.children[:worker]
      assert ref.agent_module == SomeChildModule
      assert ref.agent_id == "orch-child-001"
      assert ref.status == :running
    end
  end

  describe "orchestrator child_exit updates children map" do
    defmodule ChildExitOrchestrator do
      use Jido.Composer.Orchestrator,
        name: "child_exit_orch",
        description: "Orchestrator for child exit tests",
        model: "test-model",
        system_prompt: "test",
        nodes: [NoopAction]
    end

    test "child_exit with normal reason sets :completed" do
      agent = ChildExitOrchestrator.new()
      {agent, _directives} = ChildExitOrchestrator.query(agent, "test")

      {agent, _} =
        ChildExitOrchestrator.cmd(
          agent,
          {:orchestrator_child_started,
           %{
             tag: :worker,
             agent_module: SomeChildModule,
             agent_id: "orch-child-002"
           }}
        )

      {agent, _} =
        ChildExitOrchestrator.cmd(
          agent,
          {:orchestrator_child_exit,
           %{
             tag: :worker,
             reason: :normal
           }}
        )

      strat = StratState.get(agent)
      assert strat.children[:worker].status == :completed
    end

    test "child_exit with error reason sets :failed" do
      agent = ChildExitOrchestrator.new()
      {agent, _directives} = ChildExitOrchestrator.query(agent, "test")

      {agent, _} =
        ChildExitOrchestrator.cmd(
          agent,
          {:orchestrator_child_started,
           %{
             tag: :worker,
             agent_module: SomeChildModule,
             agent_id: "orch-child-003"
           }}
        )

      {agent, _} =
        ChildExitOrchestrator.cmd(
          agent,
          {:orchestrator_child_exit,
           %{
             tag: :worker,
             reason: {:error, :timeout}
           }}
        )

      strat = StratState.get(agent)
      assert strat.children[:worker].status == :failed
    end
  end

  describe "ChildRef survives checkpoint serialization" do
    alias Jido.Composer.Checkpoint

    test "ChildRef round-trips through term_to_binary" do
      agent = ChildTrackingWorkflow.new()
      {agent, _directives} = ChildTrackingWorkflow.run(agent, %{tag: "test"})

      {agent, _} =
        ChildTrackingWorkflow.cmd(
          agent,
          {:workflow_child_started,
           %{
             tag: :process,
             agent_module: SomeChildModule,
             agent_id: "child-rt-001"
           }}
        )

      strat = StratState.get(agent)
      checkpoint_data = Checkpoint.prepare_for_checkpoint(strat)

      binary = :erlang.term_to_binary(checkpoint_data, [:compressed])
      restored = :erlang.binary_to_term(binary)

      assert %ChildRef{} = ref = restored.children[:process]
      assert ref.agent_module == SomeChildModule
      assert ref.agent_id == "child-rt-001"
      assert ref.status == :running
    end
  end
end
