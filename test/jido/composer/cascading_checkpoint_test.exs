defmodule Jido.Composer.CascadingCheckpointTest do
  use ExUnit.Case, async: true

  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.Composer.TestActions.NoopAction

  # -- Test workflow for cascading signals --

  defmodule CascadingWorkflow do
    use Jido.Composer.Workflow,
      name: "cascading_workflow",
      description: "Workflow for cascading checkpoint tests",
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

  describe "child_hibernated signal" do
    test "updates parent ChildRef to :paused with checkpoint_key" do
      agent = CascadingWorkflow.new()
      {agent, _directives} = CascadingWorkflow.run(agent, %{tag: "test"})

      # First register the child
      {agent, _} =
        CascadingWorkflow.cmd(
          agent,
          {:workflow_child_started,
           %{
             tag: :worker,
             agent_module: SomeChildModule,
             agent_id: "child-hibernate-001"
           }}
        )

      # Now child hibernates
      {agent, _} =
        CascadingWorkflow.cmd(
          agent,
          {:child_hibernated,
           %{
             tag: :worker,
             checkpoint_key: "ck-child-001",
             suspension_id: "suspend-child-001"
           }}
        )

      strat = StratState.get(agent)
      ref = strat.children[:worker]
      assert ref.status == :paused
      assert ref.checkpoint_key == "ck-child-001"
      assert ref.suspension_id == "suspend-child-001"
    end

    test "parent checkpoint includes updated ChildRef" do
      alias Jido.Composer.Checkpoint

      agent = CascadingWorkflow.new()
      {agent, _directives} = CascadingWorkflow.run(agent, %{tag: "test"})

      {agent, _} =
        CascadingWorkflow.cmd(
          agent,
          {:workflow_child_started,
           %{
             tag: :worker,
             agent_module: SomeChildModule,
             agent_id: "child-cp-001"
           }}
        )

      {agent, _} =
        CascadingWorkflow.cmd(
          agent,
          {:child_hibernated,
           %{
             tag: :worker,
             checkpoint_key: "ck-cp-001",
             suspension_id: "suspend-cp-001"
           }}
        )

      strat = StratState.get(agent)
      checkpoint_data = Checkpoint.prepare_for_checkpoint(strat)

      # Verify checkpoint includes the paused child
      assert checkpoint_data.children[:worker].status == :paused
      assert checkpoint_data.children[:worker].checkpoint_key == "ck-cp-001"
    end

    test "multiple children can hibernate independently" do
      agent = CascadingWorkflow.new()
      {agent, _directives} = CascadingWorkflow.run(agent, %{tag: "test"})

      # Start two children
      {agent, _} =
        CascadingWorkflow.cmd(
          agent,
          {:workflow_child_started,
           %{
             tag: :worker_a,
             agent_module: SomeChildModule,
             agent_id: "child-a"
           }}
        )

      {agent, _} =
        CascadingWorkflow.cmd(
          agent,
          {:workflow_child_started,
           %{
             tag: :worker_b,
             agent_module: SomeChildModule,
             agent_id: "child-b"
           }}
        )

      # Hibernate first child
      {agent, _} =
        CascadingWorkflow.cmd(
          agent,
          {:child_hibernated,
           %{
             tag: :worker_a,
             checkpoint_key: "ck-a",
             suspension_id: "suspend-a"
           }}
        )

      strat = StratState.get(agent)
      assert strat.children[:worker_a].status == :paused
      assert strat.children[:worker_b].status == :running

      # Hibernate second child
      {agent, _} =
        CascadingWorkflow.cmd(
          agent,
          {:child_hibernated,
           %{
             tag: :worker_b,
             checkpoint_key: "ck-b",
             suspension_id: "suspend-b"
           }}
        )

      strat = StratState.get(agent)
      assert strat.children[:worker_a].status == :paused
      assert strat.children[:worker_b].status == :paused
    end
  end

  describe "child_hibernated signal routes" do
    test "workflow routes composer.child.hibernated to child_hibernated" do
      ctx = %{strategy_opts: []}
      routes = Jido.Composer.Workflow.Strategy.signal_routes(ctx)

      assert {"composer.child.hibernated", {:strategy_cmd, :child_hibernated}} in routes
    end

    test "orchestrator routes composer.child.hibernated to child_hibernated" do
      ctx = %{strategy_opts: []}
      routes = Jido.Composer.Orchestrator.Strategy.signal_routes(ctx)

      assert {"composer.child.hibernated", {:strategy_cmd, :child_hibernated}} in routes
    end
  end

  describe "CheckpointAndStop directive" do
    alias Jido.Composer.Directive.CheckpointAndStop

    test "creates directive with required fields" do
      suspension = %{id: "suspend-test", reason: :external_job}

      directive = %CheckpointAndStop{
        suspension: suspension,
        storage_config: %{adapter: :ets},
        checkpoint_data: %{some: "data"}
      }

      assert directive.suspension == suspension
      assert directive.storage_config == %{adapter: :ets}
      assert directive.checkpoint_data == %{some: "data"}
    end
  end

  describe "phase tracking in workflow" do
    test "dispatch_current_node for AgentNode sets child_phases to :spawning" do
      # We can't easily test dispatch_current_node directly since it's private,
      # but we can verify phase tracking via the child_started handler
      agent = CascadingWorkflow.new()
      {agent, _directives} = CascadingWorkflow.run(agent, %{tag: "test"})

      # After child_started, phase should transition to :awaiting_result
      {agent, _} =
        CascadingWorkflow.cmd(
          agent,
          {:workflow_child_started,
           %{
             tag: :process,
             agent_module: SomeChildModule,
             agent_id: "child-phase-001"
           }}
        )

      strat = StratState.get(agent)
      assert strat.child_phases[:process] == :awaiting_result
    end
  end
end
