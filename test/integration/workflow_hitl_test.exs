defmodule Jido.Composer.Integration.WorkflowHITLTest do
  use ExUnit.Case, async: true

  alias Jido.Agent.Directive
  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.Composer.Directive.SuspendForHuman
  alias Jido.Composer.HITL.{ApprovalRequest, ApprovalResponse}
  alias Jido.Composer.Node.HumanNode

  alias Jido.Composer.TestActions.{
    NoopAction,
    AccumulatorAction
  }

  # -- Workflow definitions --

  defmodule ApprovalWorkflow do
    use Jido.Composer.Workflow,
      name: "approval_workflow",
      description: "Process → Approve → Execute pipeline",
      nodes: %{
        process: AccumulatorAction,
        approval: %HumanNode{
          name: "deploy_approval",
          description: "Approve deployment",
          prompt: "Approve deployment to production?",
          allowed_responses: [:approved, :rejected]
        },
        execute: NoopAction
      },
      transitions: %{
        {:process, :ok} => :approval,
        {:approval, :approved} => :execute,
        {:approval, :rejected} => :failed,
        {:approval, :timeout} => :failed,
        {:execute, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :process
  end

  defmodule TimeoutWorkflow do
    use Jido.Composer.Workflow,
      name: "timeout_workflow",
      description: "Workflow with HITL timeout transition",
      nodes: %{
        check: NoopAction,
        approval: %HumanNode{
          name: "timeout_approval",
          description: "Approve with timeout",
          prompt: "Approve?",
          allowed_responses: [:approved, :rejected],
          timeout: 30_000,
          timeout_outcome: :timeout
        },
        fallback: NoopAction
      },
      transitions: %{
        {:check, :ok} => :approval,
        {:approval, :approved} => :done,
        {:approval, :rejected} => :failed,
        {:approval, :timeout} => :fallback,
        {:fallback, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :check
  end

  # -- Helpers --

  defp execute_workflow(agent_module, agent, directives) do
    run_directive_loop(agent_module, agent, directives)
  end

  defp run_directive_loop(_agent_module, agent, []), do: {agent, []}

  defp run_directive_loop(agent_module, agent, [directive | rest]) do
    case directive do
      %Directive.RunInstruction{instruction: instr, result_action: result_action} ->
        payload = execute_instruction(instr)
        {agent, new_directives} = agent_module.cmd(agent, {result_action, payload})
        run_directive_loop(agent_module, agent, new_directives ++ rest)

      %SuspendForHuman{} = suspend ->
        # Return the agent and remaining directives including the suspend
        {agent, [suspend | rest]}

      _other ->
        run_directive_loop(agent_module, agent, rest)
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

  describe "suspend/resume cycle" do
    test "workflow suspends at HumanNode and emits SuspendForHuman directive" do
      agent = ApprovalWorkflow.new()
      {agent, directives} = ApprovalWorkflow.run(agent, %{tag: "deploy-v1"})

      # Execute until we hit the HumanNode
      {agent, remaining} = execute_workflow(ApprovalWorkflow, agent, directives)

      # Should have a SuspendForHuman directive
      assert [%SuspendForHuman{} = suspend | _] = remaining
      assert %ApprovalRequest{} = suspend.approval_request
      assert suspend.approval_request.prompt == "Approve deployment to production?"
      assert suspend.approval_request.allowed_responses == [:approved, :rejected]
      assert suspend.approval_request.node_name == "deploy_approval"
      assert suspend.approval_request.workflow_state == :approval

      # Strategy should be in :waiting status
      strat = StratState.get(agent)
      assert strat.status == :waiting
      assert strat.pending_approval != nil
      assert strat.machine.status == :approval
    end

    test "workflow resumes on approved decision and completes" do
      agent = ApprovalWorkflow.new()
      {agent, directives} = ApprovalWorkflow.run(agent, %{tag: "deploy-v1"})
      {agent, _remaining} = execute_workflow(ApprovalWorkflow, agent, directives)

      # Resume with approval
      strat = StratState.get(agent)

      {:ok, response} =
        ApprovalResponse.new(
          request_id: strat.pending_approval.id,
          decision: :approved,
          respondent: "admin@co.com",
          comment: "Ship it!"
        )

      {agent, directives} =
        ApprovalWorkflow.cmd(agent, {:hitl_response, Map.from_struct(response)})

      # Should continue with execute node
      {agent, _} = execute_workflow(ApprovalWorkflow, agent, directives)

      strat = StratState.get(agent)
      assert strat.machine.status == :done
      assert StratState.status(agent) == :success

      # HITL response should be merged into context
      assert strat.machine.context[:hitl_response][:decision] == :approved
      assert strat.machine.context[:hitl_response][:respondent] == "admin@co.com"
    end

    test "workflow resumes on rejected decision and transitions to failed" do
      agent = ApprovalWorkflow.new()
      {agent, directives} = ApprovalWorkflow.run(agent, %{tag: "deploy-v1"})
      {agent, _remaining} = execute_workflow(ApprovalWorkflow, agent, directives)

      # Resume with rejection
      strat = StratState.get(agent)

      {:ok, response} =
        ApprovalResponse.new(
          request_id: strat.pending_approval.id,
          decision: :rejected,
          respondent: "reviewer@co.com",
          comment: "Too risky"
        )

      {agent, _directives} =
        ApprovalWorkflow.cmd(agent, {:hitl_response, Map.from_struct(response)})

      strat = StratState.get(agent)
      assert strat.machine.status == :failed
      assert StratState.status(agent) == :failure
    end

    test "rejects response with mismatched request_id" do
      agent = ApprovalWorkflow.new()
      {agent, directives} = ApprovalWorkflow.run(agent, %{tag: "deploy-v1"})
      {agent, _remaining} = execute_workflow(ApprovalWorkflow, agent, directives)

      # Resume with wrong request_id
      {:ok, response} =
        ApprovalResponse.new(
          request_id: "wrong-id",
          decision: :approved
        )

      {agent, directives} =
        ApprovalWorkflow.cmd(agent, {:hitl_response, Map.from_struct(response)})

      # Should emit an error directive
      assert [%Directive.Error{}] = directives

      # Status should still be :waiting
      strat = StratState.get(agent)
      assert strat.status == :waiting
    end

    test "rejects response with invalid decision" do
      agent = ApprovalWorkflow.new()
      {agent, directives} = ApprovalWorkflow.run(agent, %{tag: "deploy-v1"})
      {agent, _remaining} = execute_workflow(ApprovalWorkflow, agent, directives)

      strat = StratState.get(agent)

      {:ok, response} =
        ApprovalResponse.new(
          request_id: strat.pending_approval.id,
          decision: :maybe
        )

      {agent, directives} =
        ApprovalWorkflow.cmd(agent, {:hitl_response, Map.from_struct(response)})

      assert [%Directive.Error{}] = directives
      strat = StratState.get(agent)
      assert strat.status == :waiting
    end

    test "context from process step is available in ApprovalRequest" do
      agent = ApprovalWorkflow.new()
      {agent, directives} = ApprovalWorkflow.run(agent, %{tag: "deploy-v1"})
      {_agent, remaining} = execute_workflow(ApprovalWorkflow, agent, directives)

      [%SuspendForHuman{approval_request: request} | _] = remaining

      # The visible_context should contain accumulated workflow context
      assert request.visible_context[:tag] == "deploy-v1"
    end
  end

  describe "timeout outcome transition" do
    test "timeout transitions to fallback state" do
      agent = TimeoutWorkflow.new()
      {agent, directives} = TimeoutWorkflow.run(agent, %{})
      {agent, _remaining} = execute_workflow(TimeoutWorkflow, agent, directives)

      # Verify suspended
      strat = StratState.get(agent)
      assert strat.status == :waiting

      # Simulate timeout
      {agent, directives} =
        TimeoutWorkflow.cmd(agent, {:hitl_timeout, %{request_id: strat.pending_approval.id}})

      # Should continue to fallback node
      {agent, _} = execute_workflow(TimeoutWorkflow, agent, directives)

      strat = StratState.get(agent)
      assert strat.machine.status == :done
      assert StratState.status(agent) == :success
    end

    test "timeout is ignored if already resolved" do
      agent = TimeoutWorkflow.new()
      {agent, directives} = TimeoutWorkflow.run(agent, %{})
      {agent, _remaining} = execute_workflow(TimeoutWorkflow, agent, directives)

      strat = StratState.get(agent)
      request_id = strat.pending_approval.id

      # Approve first
      {:ok, response} =
        ApprovalResponse.new(request_id: request_id, decision: :approved)

      {agent, directives} =
        TimeoutWorkflow.cmd(agent, {:hitl_response, Map.from_struct(response)})

      {agent, _} = execute_workflow(TimeoutWorkflow, agent, directives)

      # Now try timeout — should be ignored (no pending request)
      {agent, directives} =
        TimeoutWorkflow.cmd(agent, {:hitl_timeout, %{request_id: request_id}})

      assert directives == []
      strat = StratState.get(agent)
      assert strat.machine.status == :done
    end
  end
end
