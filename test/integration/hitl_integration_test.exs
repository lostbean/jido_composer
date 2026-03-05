defmodule Jido.Composer.Integration.HITLIntegrationTest do
  use ExUnit.Case, async: true

  alias Jido.Agent.Directive
  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.Composer.Directive.SuspendForHuman
  alias Jido.Composer.HITL.{ApprovalResponse, ChildRef}
  alias Jido.Composer.Node.HumanNode
  alias Jido.Composer.Orchestrator.Strategy, as: OrchStrategy
  alias Jido.Composer.TestSupport.MockLLM

  alias Jido.Composer.TestActions.{
    NoopAction,
    AccumulatorAction,
    AddAction,
    EchoAction
  }

  # -- Workflow with HITL (inner child) --

  defmodule InnerWorkflow do
    use Jido.Composer.Workflow,
      name: "inner_workflow",
      description: "Workflow with approval gate",
      nodes: %{
        prepare: AccumulatorAction,
        approval: %HumanNode{
          name: "inner_approval",
          description: "Approve inner operation",
          prompt: "Approve inner step?",
          allowed_responses: [:approved, :rejected]
        },
        execute: NoopAction
      },
      transitions: %{
        {:prepare, :ok} => :approval,
        {:approval, :approved} => :execute,
        {:approval, :rejected} => :failed,
        {:execute, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :prepare
  end

  # -- Outer workflow wrapping the inner workflow as an AgentNode --

  defmodule OuterWorkflow do
    use Jido.Composer.Workflow,
      name: "outer_workflow",
      description: "Outer workflow with inner HITL workflow",
      nodes: %{
        ingest: NoopAction,
        process: {InnerWorkflow, []},
        finish: NoopAction
      },
      transitions: %{
        {:ingest, :ok} => :process,
        {:process, :ok} => :finish,
        {:process, :error} => :failed,
        {:finish, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :ingest
  end

  # -- Bare agent for orchestrator tests --

  defmodule HITLOrchAgent do
    use Jido.Agent,
      name: "hitl_orch_agent",
      description: "Bare agent for nested HITL tests",
      schema: []
  end

  # -- Helpers --

  defp make_instruction(action, params) do
    %Jido.Instruction{action: action, params: params}
  end

  defp execute_workflow_directives(agent_module, agent, directives) do
    run_wf_loop(agent_module, agent, directives)
  end

  defp run_wf_loop(_agent_module, agent, []), do: {agent, []}

  defp run_wf_loop(agent_module, agent, [directive | rest]) do
    case directive do
      %Directive.RunInstruction{instruction: instr, result_action: result_action} ->
        payload = execute_action_instruction(instr)
        {agent, new_directives} = agent_module.cmd(agent, {result_action, payload})
        run_wf_loop(agent_module, agent, new_directives ++ rest)

      %Directive.SpawnAgent{} = spawn_dir ->
        # For testing, return the spawn directive so the test can control it
        {agent, [spawn_dir | rest]}

      %SuspendForHuman{} = suspend ->
        {agent, [suspend | rest]}

      _other ->
        run_wf_loop(agent_module, agent, rest)
    end
  end

  defp execute_action_instruction(%Jido.Instruction{action: action_module, params: params}) do
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

  describe "child suspend isolation" do
    test "inner workflow suspends while outer workflow is waiting for child" do
      # Start outer workflow — it will execute ingest, then try to spawn process (inner)
      agent = OuterWorkflow.new()
      {agent, directives} = OuterWorkflow.run(agent, %{data: "test"})

      # Execute until SpawnAgent for inner workflow
      {agent, remaining} = execute_workflow_directives(OuterWorkflow, agent, directives)

      # Should have SpawnAgent directive
      assert [%Directive.SpawnAgent{agent: InnerWorkflow} | _] = remaining

      # Outer workflow's strategy should be in :running status
      # (it dispatched but hasn't received child_started yet)
      outer_strat = StratState.get(agent)
      assert outer_strat.machine.status == :process

      # Simulate inner workflow independently
      inner_agent = InnerWorkflow.new()
      {inner_agent, inner_directives} = InnerWorkflow.run(inner_agent, %{tag: "inner-data"})

      {inner_agent, inner_remaining} =
        execute_workflow_directives(InnerWorkflow, inner_agent, inner_directives)

      # Inner workflow should be suspended at HITL
      assert [%SuspendForHuman{} | _] = inner_remaining
      inner_strat = StratState.get(inner_agent)
      assert inner_strat.status == :waiting
      assert inner_strat.machine.status == :approval

      # Outer workflow is UNAWARE of inner suspension — it's just waiting for child result
      # (status hasn't changed)
      outer_strat = StratState.get(agent)
      assert outer_strat.machine.status == :process
    end

    test "inner workflow resume completes and can provide result to outer" do
      # Run inner workflow to suspension
      inner_agent = InnerWorkflow.new()
      {inner_agent, inner_directives} = InnerWorkflow.run(inner_agent, %{tag: "inner-data"})

      {inner_agent, _inner_remaining} =
        execute_workflow_directives(InnerWorkflow, inner_agent, inner_directives)

      # Get pending approval
      inner_strat = StratState.get(inner_agent)
      request_id = inner_strat.pending_approval.id

      # Approve
      {:ok, response} = ApprovalResponse.new(request_id: request_id, decision: :approved)

      {inner_agent, directives} =
        InnerWorkflow.cmd(inner_agent, {:hitl_response, Map.from_struct(response)})

      {inner_agent, _} = execute_workflow_directives(InnerWorkflow, inner_agent, directives)

      inner_strat = StratState.get(inner_agent)
      assert inner_strat.machine.status == :done
      assert StratState.status(inner_agent) == :success

      # The inner result could be provided to outer as child_result
      # (In real system, emit_to_parent handles this)
    end
  end

  describe "cascading checkpoint" do
    test "both inner and outer strategy states are independently serializable" do
      # Outer workflow at :process state
      outer_agent = OuterWorkflow.new()
      {outer_agent, directives} = OuterWorkflow.run(outer_agent, %{data: "test"})

      {outer_agent, _remaining} =
        execute_workflow_directives(OuterWorkflow, outer_agent, directives)

      # Inner workflow suspended at HITL
      inner_agent = InnerWorkflow.new()
      {inner_agent, inner_directives} = InnerWorkflow.run(inner_agent, %{tag: "inner-data"})

      {inner_agent, _inner_remaining} =
        execute_workflow_directives(InnerWorkflow, inner_agent, inner_directives)

      # Both are independently serializable
      outer_binary = :erlang.term_to_binary(StratState.get(outer_agent), [:compressed])
      inner_binary = :erlang.term_to_binary(StratState.get(inner_agent), [:compressed])

      outer_restored = :erlang.binary_to_term(outer_binary)
      inner_restored = :erlang.binary_to_term(inner_binary)

      assert outer_restored.machine.status == :process
      assert inner_restored.status == :waiting
      assert inner_restored.pending_approval != nil
    end

    test "ChildRef can track child hibernation status" do
      ref =
        ChildRef.new(
          agent_module: InnerWorkflow,
          agent_id: "inner-123",
          tag: :process,
          checkpoint_key: {"checkpoints", "inner-123"},
          status: :running
        )

      # Simulate child hibernation
      ref = %{ref | status: :paused}

      # Serialize with parent state
      parent_state = %{
        machine_status: :process,
        child_ref: ref
      }

      binary = :erlang.term_to_binary(parent_state)
      restored = :erlang.binary_to_term(binary)

      assert restored.child_ref.status == :paused
      assert restored.child_ref.agent_module == InnerWorkflow
      assert restored.child_ref.checkpoint_key == {"checkpoints", "inner-123"}
    end
  end

  describe "top-down resume" do
    test "inner workflow can be restored and resumed from serialized state" do
      # Run inner to suspension
      inner_agent = InnerWorkflow.new()
      {inner_agent, inner_directives} = InnerWorkflow.run(inner_agent, %{tag: "persist-test"})

      {inner_agent, _remaining} =
        execute_workflow_directives(InnerWorkflow, inner_agent, inner_directives)

      # Checkpoint
      inner_strat = StratState.get(inner_agent)
      binary = :erlang.term_to_binary(inner_strat, [:compressed])

      # Simulate death and restore
      fresh_agent = InnerWorkflow.new()
      restored_strat = :erlang.binary_to_term(binary)
      restored_agent = StratState.put(fresh_agent, restored_strat)

      # Resume with approval
      request_id = restored_strat.pending_approval.id
      {:ok, response} = ApprovalResponse.new(request_id: request_id, decision: :approved)

      {resumed_agent, directives} =
        InnerWorkflow.cmd(restored_agent, {:hitl_response, Map.from_struct(response)})

      {final_agent, _} = execute_workflow_directives(InnerWorkflow, resumed_agent, directives)

      final_strat = StratState.get(final_agent)
      assert final_strat.machine.status == :done
      assert StratState.status(final_agent) == :success
    end

    test "orchestrator with gated tool can be checkpointed and resumed" do
      strategy_opts = [
        nodes: [AddAction, EchoAction],
        llm_module: MockLLM,
        model: "mock:test-model",
        system_prompt: "Test",
        max_iterations: 10,
        gated_nodes: ["add"]
      ]

      agent = HITLOrchAgent.new()
      {agent, _} = OrchStrategy.init(agent, %{strategy_opts: strategy_opts})

      tool_call = %{id: "call_1", name: "add", arguments: %{"value" => 5.0, "amount" => 3.0}}
      MockLLM.setup([{:tool_calls, [tool_call]}, {:final_answer, "8.0"}])

      {agent, directives} =
        OrchStrategy.cmd(agent, [make_instruction(:orchestrator_start, %{query: "Add 5+3"})], %{})

      # Execute LLM call to get tool calls, then encounter the suspend
      {agent, _remaining} = run_orch_directives(agent, directives)

      # Checkpoint the state
      strat = StratState.get(agent)
      assert strat.status == :awaiting_approval
      binary = :erlang.term_to_binary(strat, [:compressed])

      # Restore
      fresh_agent = HITLOrchAgent.new()
      restored = :erlang.binary_to_term(binary)
      restored_agent = StratState.put(fresh_agent, restored)

      # Resume with approval
      [{request_id, _}] = Map.to_list(restored.gated_calls)
      {:ok, response} = ApprovalResponse.new(request_id: request_id, decision: :approved)

      # Need MockLLM setup for the final answer after tool execution
      MockLLM.setup([{:final_answer, "8.0"}])

      {resumed_agent, directives} =
        OrchStrategy.cmd(
          restored_agent,
          [make_instruction(:hitl_response, Map.from_struct(response))],
          %{}
        )

      {final_agent, _} = run_orch_directives(resumed_agent, directives)

      final_strat = StratState.get(final_agent)
      assert final_strat.status == :completed
      assert final_strat.result == "8.0"
    end
  end

  # -- Orchestrator directive loop --

  defp run_orch_directives(agent, []), do: {agent, []}

  defp run_orch_directives(agent, [directive | rest]) do
    case directive do
      %Directive.RunInstruction{
        instruction: %Jido.Instruction{action: Jido.Composer.Orchestrator.LLMAction} = instr,
        result_action: result_action
      } ->
        payload = execute_llm(instr)

        {agent, new_directives} =
          OrchStrategy.cmd(agent, [make_instruction(result_action, payload)], %{})

        run_orch_directives(agent, new_directives ++ rest)

      %Directive.RunInstruction{
        instruction: %Jido.Instruction{action: action_module, params: params},
        result_action: result_action,
        meta: meta
      } ->
        payload =
          case Jido.Exec.run(action_module, params) do
            {:ok, result} -> %{status: :ok, result: result, meta: meta || %{}}
            {:error, reason} -> %{status: :error, result: reason, meta: meta || %{}}
          end

        {agent, new_directives} =
          OrchStrategy.cmd(agent, [make_instruction(result_action, payload)], %{})

        run_orch_directives(agent, new_directives ++ rest)

      %SuspendForHuman{} = suspend ->
        {agent, [suspend | rest]}

      _other ->
        run_orch_directives(agent, rest)
    end
  end

  defp execute_llm(%Jido.Instruction{params: params}) do
    llm_module = params[:llm_module]
    conversation = params[:conversation]
    tool_results = params[:tool_results] || []
    tools = params[:tools] || []
    opts = params[:opts] || []

    case llm_module.generate(conversation, tool_results, tools, opts) do
      {:ok, response, updated_conversation} ->
        %{
          status: :ok,
          result: %{response: response, conversation: updated_conversation},
          meta: %{}
        }

      {:error, reason} ->
        %{status: :error, result: %{error: reason}, meta: %{}}
    end
  end
end
