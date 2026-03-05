defmodule Jido.Composer.Integration.HITLPersistenceTest do
  use ExUnit.Case, async: true

  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.Composer.HITL.ApprovalResponse
  alias Jido.Composer.HITL.ChildRef
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

      %Jido.Composer.Directive.SuspendForHuman{} = suspend ->
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
      assert strat.pending_approval != nil

      # Serialize the entire strategy state
      binary = :erlang.term_to_binary(strat, [:compressed])
      assert is_binary(binary)
      assert byte_size(binary) > 0

      # Deserialize
      restored = :erlang.binary_to_term(binary)
      assert restored.status == :waiting
      assert restored.pending_approval.id == strat.pending_approval.id
      assert restored.pending_approval.prompt == "Approve processing?"
      assert restored.machine.status == :approval
      assert restored.machine.context[:tag] == "test"
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
      assert restored.pending_approval.id == strat.pending_approval.id

      # Resume with approval
      {:ok, response} =
        ApprovalResponse.new(
          request_id: restored.pending_approval.id,
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
      request_id = strat.pending_approval.id

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
end
