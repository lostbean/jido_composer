defmodule Jido.Composer.Integration.WorkflowFanOutTest do
  use ExUnit.Case, async: true

  alias Jido.Agent.Directive
  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.Composer.Node.ActionNode
  alias Jido.Composer.Node.FanOutNode
  alias Jido.Composer.TestActions.{AddAction, EchoAction, FailAction}

  # -- Workflow with FanOutNode --

  # A workflow where a middle step uses FanOutNode for parallel execution.
  # FanOutNode is passed as a pre-built struct since it needs branches configuration.
  defmodule ParallelStepWorkflow do
    {:ok, echo_node1} = ActionNode.new(EchoAction)
    {:ok, echo_node2} = ActionNode.new(EchoAction)

    {:ok, fan_out} =
      FanOutNode.new(
        name: "parallel_review",
        branches: [review_a: echo_node1, review_b: echo_node2]
      )

    use Jido.Composer.Workflow,
      name: "parallel_step_workflow",
      description: "Workflow with a FanOutNode step",
      nodes: %{
        prepare: EchoAction,
        review: fan_out,
        finalize: EchoAction
      },
      transitions: %{
        {:prepare, :ok} => :review,
        {:review, :ok} => :finalize,
        {:finalize, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :prepare
  end

  # FanOutNode as the only step in a workflow
  defmodule SingleFanOutWorkflow do
    {:ok, add_node} = ActionNode.new(AddAction)
    {:ok, echo_node} = ActionNode.new(EchoAction)

    {:ok, fan_out} =
      FanOutNode.new(
        name: "parallel_compute",
        branches: [add: add_node, echo: echo_node]
      )

    use Jido.Composer.Workflow,
      name: "single_fan_out",
      nodes: %{
        compute: fan_out
      },
      transitions: %{
        {:compute, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :compute
  end

  # FanOutNode with a failing branch
  defmodule FailingFanOutWorkflow do
    {:ok, fail_node} = ActionNode.new(FailAction)
    {:ok, echo_node} = ActionNode.new(EchoAction)

    {:ok, fan_out} =
      FanOutNode.new(
        name: "failing_review",
        branches: [echo: echo_node, fail: fail_node],
        on_error: :fail_fast
      )

    use Jido.Composer.Workflow,
      name: "failing_fan_out",
      nodes: %{
        review: fan_out
      },
      transitions: %{
        {:review, :ok} => :done,
        {:review, :error} => :failed,
        {:_, :error} => :failed
      },
      initial: :review
  end

  # -- Helpers --

  defp execute_workflow(agent_module, agent, directives) do
    run_directive_loop(agent_module, agent, directives)
  end

  defp run_directive_loop(_agent_module, agent, []), do: agent

  defp run_directive_loop(agent_module, agent, [directive | rest]) do
    case directive do
      %Directive.RunInstruction{instruction: instr, result_action: result_action} ->
        payload = execute_instruction(instr)
        {agent, new_directives} = agent_module.cmd(agent, {result_action, payload})
        run_directive_loop(agent_module, agent, new_directives ++ rest)

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

  describe "FanOutNode in workflow" do
    test "strategy recognizes FanOutNode struct in nodes" do
      agent = ParallelStepWorkflow.new()
      strat = StratState.get(agent)

      review_node = strat.machine.nodes[:review]
      assert %FanOutNode{} = review_node
      assert review_node.name == "parallel_review"
    end

    test "FanOutNode executes inline during workflow (no directive emitted)" do
      agent = SingleFanOutWorkflow.new()

      {agent, directives} =
        SingleFanOutWorkflow.run(agent, %{value: 1.0, amount: 2.0, message: "test"})

      # FanOutNode executes inline — no directives needed, workflow completes immediately
      assert directives == []

      strat = StratState.get(agent)
      assert strat.machine.status == :done
      assert StratState.status(agent) == :success
    end

    test "FanOutNode merged result is scoped under state name" do
      agent = SingleFanOutWorkflow.new()
      {agent, _} = SingleFanOutWorkflow.run(agent, %{value: 1.0, amount: 2.0, message: "hi"})

      strat = StratState.get(agent)
      ctx = strat.machine.context

      # FanOutNode results are scoped under the state name :compute
      assert ctx[:compute][:add][:result] == 3.0
      assert ctx[:compute][:echo][:echoed] == "hi"
    end

    test "completes workflow with mixed ActionNode and FanOutNode steps" do
      agent = ParallelStepWorkflow.new()
      {agent, directives} = ParallelStepWorkflow.run(agent, %{message: "start"})

      agent = execute_workflow(ParallelStepWorkflow, agent, directives)

      strat = StratState.get(agent)
      assert strat.machine.status == :done
      assert StratState.status(agent) == :success
    end

    test "FanOutNode result feeds into subsequent steps" do
      agent = ParallelStepWorkflow.new()
      {agent, directives} = ParallelStepWorkflow.run(agent, %{message: "start"})

      agent = execute_workflow(ParallelStepWorkflow, agent, directives)

      strat = StratState.get(agent)
      ctx = strat.machine.context

      # Prepare step scoped its result
      assert ctx[:prepare][:echoed] == "start"
      # Review (FanOutNode) step scoped its merged result
      assert Map.has_key?(ctx, :review)
    end

    test "FanOutNode branch failure transitions to error state" do
      agent = FailingFanOutWorkflow.new()
      {agent, _directives} = FailingFanOutWorkflow.run(agent, %{message: "hello"})

      strat = StratState.get(agent)
      assert strat.machine.status == :failed
      assert StratState.status(agent) == :failure
    end
  end
end
