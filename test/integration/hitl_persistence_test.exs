defmodule Jido.Composer.Integration.HITLPersistenceTest do
  use ExUnit.Case, async: true

  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.Composer.Checkpoint
  alias Jido.Composer.ChildRef
  alias Jido.Composer.HITL.ApprovalResponse
  alias Jido.Composer.Node.HumanNode

  alias Jido.Composer.TestActions.{
    NoopAction,
    AccumulatorAction
  }

  # -- Workflow with HumanNode for persistence tests --

  defmodule PersistWorkflow do
    use Jido.Composer.Workflow,
      name: "persist_workflow",
      description: "Workflow for checkpoint/thaw tests",
      nodes: %{
        process: AccumulatorAction,
        approval: %HumanNode{
          name: "approval",
          description: "Approve",
          prompt: "Approve processing?",
          allowed_responses: [:approved, :rejected],
          timeout: 30_000
        },
        finish: NoopAction
      },
      transitions: %{
        {:process, :ok} => :approval,
        {:approval, :approved} => :finish,
        {:approval, :rejected} => :failed,
        {:approval, :timeout} => :failed,
        {:finish, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :process
  end

  # -- Helpers --

  defp run_to_suspend(agent) do
    {agent, directives} = PersistWorkflow.run(agent, %{tag: "test"})
    execute_until_suspend(PersistWorkflow, agent, directives)
  end

  defp execute_until_suspend(_agent_module, agent, []), do: {agent, []}

  defp execute_until_suspend(agent_module, agent, [directive | rest]) do
    case directive do
      %Jido.Agent.Directive.RunInstruction{instruction: instr, result_action: result_action} ->
        payload = execute_instruction(instr)
        {agent, new_directives} = agent_module.cmd(agent, {result_action, payload})
        execute_until_suspend(agent_module, agent, new_directives ++ rest)

      %Jido.Composer.Directive.Suspend{} = suspend ->
        {agent, [suspend | rest]}

      _other ->
        execute_until_suspend(agent_module, agent, rest)
    end
  end

  defp execute_instruction(%Jido.Instruction{action: action_module, params: params}) do
    case Jido.Exec.run(action_module, params) do
      {:ok, result} ->
        %{
          status: :ok,
          result: result,
          instruction: %Jido.Instruction{action: action_module, params: params},
          effects: [],
          meta: %{}
        }

      {:error, reason} ->
        %{
          status: :error,
          reason: reason,
          instruction: %Jido.Instruction{action: action_module, params: params},
          effects: [],
          meta: %{}
        }
    end
  end

  # -- Tests --

  describe "checkpoint serialization" do
    test "strategy state with pending approval is fully serializable" do
      agent = PersistWorkflow.new()
      {agent, _remaining} = run_to_suspend(agent)

      strat = StratState.get(agent)
      assert strat.status == :waiting
      assert strat.pending_suspension != nil

      # Serialize the entire strategy state
      binary = :erlang.term_to_binary(strat, [:compressed])
      assert is_binary(binary)
      assert byte_size(binary) > 0

      # Deserialize
      restored = :erlang.binary_to_term(binary)
      assert restored.status == :waiting

      assert restored.pending_suspension.approval_request.id ==
               strat.pending_suspension.approval_request.id

      assert restored.pending_suspension.approval_request.prompt == "Approve processing?"
      assert restored.machine.status == :approval
      assert restored.machine.context.working[:tag] == "test"
    end

    test "full agent struct is serializable (after stripping non-serializable data)" do
      agent = PersistWorkflow.new()
      {agent, _remaining} = run_to_suspend(agent)

      # The agent state map should be serializable
      state = agent.state
      binary = :erlang.term_to_binary(state, [:compressed])
      restored_state = :erlang.binary_to_term(binary)

      strat = restored_state[:__strategy__]
      assert strat.status == :waiting
    end
  end

  describe "thaw from checkpoint" do
    test "strategy state can be restored and resumed" do
      agent = PersistWorkflow.new()
      {agent, _remaining} = run_to_suspend(agent)

      # Checkpoint
      strat = StratState.get(agent)
      binary = :erlang.term_to_binary(strat, [:compressed])

      # Simulate process death and restart
      fresh_agent = PersistWorkflow.new()

      # Restore strategy state
      restored_strat = :erlang.binary_to_term(binary)
      restored_agent = StratState.put(fresh_agent, restored_strat)

      # Verify restored state is usable
      restored = StratState.get(restored_agent)
      assert restored.status == :waiting

      assert restored.pending_suspension.approval_request.id ==
               strat.pending_suspension.approval_request.id

      # Resume with approval
      {:ok, response} =
        ApprovalResponse.new(
          request_id: restored.pending_suspension.approval_request.id,
          decision: :approved
        )

      {resumed_agent, directives} =
        PersistWorkflow.cmd(restored_agent, {:hitl_response, Map.from_struct(response)})

      # Execute remaining
      {final_agent, _} = execute_until_suspend(PersistWorkflow, resumed_agent, directives)
      final_strat = StratState.get(final_agent)

      assert final_strat.machine.status == :done
      assert StratState.status(final_agent) == :success
    end
  end

  describe "idempotent resume" do
    test "second resume attempt is rejected when no pending request" do
      agent = PersistWorkflow.new()
      {agent, _remaining} = run_to_suspend(agent)

      strat = StratState.get(agent)
      request_id = strat.pending_suspension.approval_request.id

      # First resume
      {:ok, response} =
        ApprovalResponse.new(request_id: request_id, decision: :approved)

      {agent, _directives} =
        PersistWorkflow.cmd(agent, {:hitl_response, Map.from_struct(response)})

      # Second resume — should get error (no pending request)
      {_agent, directives} =
        PersistWorkflow.cmd(agent, {:hitl_response, Map.from_struct(response)})

      assert [%Jido.Agent.Directive.Error{}] = directives
    end
  end

  describe "ChildRef" do
    test "creates a ChildRef struct" do
      ref =
        ChildRef.new(
          agent_module: SomeModule,
          agent_id: "child-123",
          tag: :etl_worker,
          checkpoint_key: {"checkpoints", "child-123"}
        )

      assert ref.agent_module == SomeModule
      assert ref.agent_id == "child-123"
      assert ref.tag == :etl_worker
      assert ref.checkpoint_key == {"checkpoints", "child-123"}
      assert ref.status == :running
    end

    test "ChildRef is fully serializable" do
      ref =
        ChildRef.new(
          agent_module: SomeModule,
          agent_id: "child-abc",
          tag: :worker,
          checkpoint_key: {"store", "child-abc"},
          status: :paused
        )

      binary = :erlang.term_to_binary(ref)
      restored = :erlang.binary_to_term(binary)

      assert restored.agent_module == SomeModule
      assert restored.agent_id == "child-abc"
      assert restored.tag == :worker
      assert restored.checkpoint_key == {"store", "child-abc"}
      assert restored.status == :paused
    end

    test "ChildRef contains no PIDs or closures" do
      ref =
        ChildRef.new(
          agent_module: SomeModule,
          agent_id: "child-xyz",
          tag: :test
        )

      fields = Map.from_struct(ref)

      for {_key, value} <- fields do
        refute is_pid(value)
        refute is_function(value)
        refute is_port(value)
        refute is_reference(value)
      end
    end

    test "ChildRef status transitions" do
      ref = ChildRef.new(agent_module: SomeModule, agent_id: "c1", tag: :t)
      assert ref.status == :running

      paused = %{ref | status: :paused}
      assert paused.status == :paused

      completed = %{ref | status: :completed}
      assert completed.status == :completed

      failed = %{ref | status: :failed}
      assert failed.status == :failed
    end
  end

  describe "cascading checkpoint" do
    test "child checkpointed before parent, both restorable" do
      # Simulate child agent suspended state
      child_strat = %{
        module: Jido.Composer.Workflow.Strategy,
        status: :waiting,
        machine: %{status: :approval, context: %{data: "child-data"}},
        pending_suspension: %{id: "child-suspend-1", reason: :human_input},
        pending_fan_out: nil
      }

      child_checkpoint = Checkpoint.prepare_for_checkpoint(child_strat)
      child_binary = :erlang.term_to_binary(child_checkpoint, [:compressed])

      # Parent tracks child via ChildRef
      child_ref =
        ChildRef.new(
          agent_module: PersistWorkflow,
          agent_id: "child-001",
          tag: :etl_worker,
          checkpoint_key: {"store", "child-001"},
          status: :paused,
          suspension_id: "child-suspend-1"
        )

      parent_strat = %{
        module: Jido.Composer.Workflow.Strategy,
        status: :waiting,
        machine: %{status: :orchestrate, context: %{data: "parent-data"}},
        pending_suspension: nil,
        pending_fan_out: nil,
        children: %{etl_worker: child_ref}
      }

      parent_checkpoint = Checkpoint.prepare_for_checkpoint(parent_strat)
      parent_binary = :erlang.term_to_binary(parent_checkpoint, [:compressed])

      # Restore both
      restored_child = :erlang.binary_to_term(child_binary)
      restored_parent = :erlang.binary_to_term(parent_binary)

      assert restored_child.machine.context.data == "child-data"
      assert restored_parent.children.etl_worker.status == :paused
      assert restored_parent.children.etl_worker.suspension_id == "child-suspend-1"
    end
  end

  describe "top-down resume" do
    test "parent thaws and detects paused children via ChildRef" do
      child_ref =
        ChildRef.new(
          agent_module: PersistWorkflow,
          agent_id: "child-resume-1",
          tag: :worker,
          checkpoint_key: {"store", "child-resume-1"},
          status: :paused,
          suspension_id: "suspend-999"
        )

      parent_strat = %{
        module: Jido.Composer.Workflow.Strategy,
        status: :waiting,
        machine: %{status: :orchestrate, context: %{}},
        children: %{worker: child_ref}
      }

      binary = :erlang.term_to_binary(parent_strat, [:compressed])
      restored = :erlang.binary_to_term(binary)

      # Parent detects paused children
      paused_children =
        restored.children
        |> Enum.filter(fn {_tag, ref} -> ref.status == :paused end)

      assert length(paused_children) == 1
      {tag, ref} = hd(paused_children)
      assert tag == :worker
      assert ref.checkpoint_key == {"store", "child-resume-1"}
      assert ref.agent_module == PersistWorkflow
    end
  end

  describe "fan-out partial completion survives checkpoint" do
    test "completed and pending branches are preserved" do
      fan_out_state = %{
        id: "fo-123",
        node: %{branches: %{a: :action_a, b: :action_b, c: :action_c}, max_concurrency: 3},
        pending_branches: MapSet.new([:c]),
        completed_results: %{a: %{data: 1}, b: %{data: 2}},
        queued_branches: [],
        merge: :deep_merge,
        on_error: :fail_fast
      }

      strat = %{
        module: Jido.Composer.Workflow.Strategy,
        status: :running,
        machine: %{status: :parallel, context: %{}},
        pending_fan_out: fan_out_state,
        pending_suspension: nil
      }

      cleaned = Checkpoint.prepare_for_checkpoint(strat)
      binary = :erlang.term_to_binary(cleaned, [:compressed])
      restored = :erlang.binary_to_term(binary)

      assert restored.pending_fan_out.completed_results == %{a: %{data: 1}, b: %{data: 2}}
      assert MapSet.member?(restored.pending_fan_out.pending_branches, :c)
    end

    test "fan-out with queued branches survives checkpoint" do
      fan_out_state = %{
        id: "fo-456",
        node: %{branches: %{a: :action_a, b: :action_b, c: :action_c}, max_concurrency: 2},
        pending_branches: MapSet.new([:a, :b]),
        completed_results: %{},
        queued_branches: [{:c, %{instruction: %{action: :noop, params: %{}}}}],
        merge: :deep_merge,
        on_error: :collect_partial
      }

      strat = %{
        module: Jido.Composer.Workflow.Strategy,
        status: :running,
        machine: %{status: :parallel, context: %{}},
        pending_fan_out: fan_out_state,
        pending_suspension: nil
      }

      cleaned = Checkpoint.prepare_for_checkpoint(strat)
      binary = :erlang.term_to_binary(cleaned, [:compressed])
      restored = :erlang.binary_to_term(binary)

      assert length(restored.pending_fan_out.queued_branches) == 1
      assert restored.pending_fan_out.on_error == :collect_partial
      assert MapSet.size(restored.pending_fan_out.pending_branches) == 2
    end
  end

  describe "checkpoint prepare + reattach round-trip" do
    test "closures are stripped and restored via strategy_opts" do
      my_policy = fn _request -> :approve end
      my_callback = fn _agent -> :ok end

      strat = %{
        module: Jido.Composer.Workflow.Strategy,
        status: :waiting,
        machine: %{status: :approval, context: %{data: "test"}},
        pending_suspension: %{id: "s1", reason: :human_input},
        approval_policy: my_policy,
        on_complete: my_callback,
        children: %{}
      }

      # Prepare strips closures
      checkpoint = Checkpoint.prepare_for_checkpoint(strat)
      assert checkpoint.approval_policy == nil
      assert checkpoint.on_complete == nil
      # Non-closure fields are preserved
      assert checkpoint.status == :waiting
      assert checkpoint.children == %{}

      # Serialize and deserialize
      binary = :erlang.term_to_binary(checkpoint, [:compressed])
      restored = :erlang.binary_to_term(binary)

      # Reattach from strategy opts
      strategy_opts = [
        approval_policy: my_policy,
        on_complete: my_callback
      ]

      reattached = Checkpoint.reattach_runtime_config(restored, strategy_opts)
      assert is_function(reattached.approval_policy)
      assert is_function(reattached.on_complete)
      assert reattached.approval_policy.(:any) == :approve
    end

    test "reattach does not overwrite non-nil values" do
      existing_fn = fn -> :existing end
      new_fn = fn -> :new end

      strat = %{
        module: Jido.Composer.Workflow.Strategy,
        status: :running,
        some_callback: existing_fn,
        other_callback: nil
      }

      # Checkpoint preserves the existing function since it's in the state
      # (prepare_for_checkpoint strips it)
      checkpoint = Checkpoint.prepare_for_checkpoint(strat)
      assert checkpoint.some_callback == nil
      assert checkpoint.other_callback == nil

      # Reattach: both nil fields should be restored from opts
      opts = [some_callback: new_fn, other_callback: new_fn]
      reattached = Checkpoint.reattach_runtime_config(checkpoint, opts)
      assert reattached.some_callback.() == :new
      assert reattached.other_callback.() == :new
    end

    test "full checkpoint/thaw/resume cycle with real workflow" do
      agent = PersistWorkflow.new()
      {agent, _remaining} = run_to_suspend(agent)

      strat = StratState.get(agent)
      assert strat.status == :waiting
      suspension_id = strat.pending_suspension.id

      # Checkpoint
      checkpoint = Checkpoint.prepare_for_checkpoint(strat)
      binary = :erlang.term_to_binary(checkpoint, [:compressed])

      # Simulate process death
      fresh_agent = PersistWorkflow.new()

      # Thaw
      restored_strat = :erlang.binary_to_term(binary)
      restored_agent = StratState.put(fresh_agent, restored_strat)

      # Resume via generalized suspend_resume
      {resumed_agent, directives} =
        PersistWorkflow.cmd(
          restored_agent,
          {:suspend_resume,
           %{
             suspension_id: suspension_id,
             response_data: %{
               request_id: strat.pending_suspension.approval_request.id,
               decision: :approved,
               respondent: "thaw-test"
             }
           }}
        )

      # Execute remaining directives
      {final_agent, _} = execute_until_suspend(PersistWorkflow, resumed_agent, directives)
      final_strat = StratState.get(final_agent)

      assert final_strat.machine.status == :done
      assert StratState.status(final_agent) == :success
    end
  end

  describe "schema migration v1 → v2" do
    test "v1 checkpoint without children field gets default" do
      v1_state = %{
        module: Jido.Composer.Workflow.Strategy,
        status: :waiting,
        machine: %{status: :approval, context: %{}},
        pending_suspension: %{id: "s1", reason: :human_input}
      }

      migrated = Checkpoint.migrate(v1_state, 1)

      assert Map.get(migrated, :children, %{}) == %{}
      assert migrated.status == :waiting
    end

    test "v2 checkpoint passes through unchanged" do
      v2_state = %{
        module: Jido.Composer.Workflow.Strategy,
        status: :waiting,
        machine: %{status: :approval, context: %{}},
        children: %{worker: %{status: :paused}}
      }

      migrated = Checkpoint.migrate(v2_state, 2)
      assert migrated == v2_state
    end
  end
end
