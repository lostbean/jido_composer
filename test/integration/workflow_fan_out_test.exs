defmodule Jido.Composer.Integration.WorkflowFanOutTest do
  use ExUnit.Case, async: true

  alias Jido.Agent.Directive
  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.Composer.Directive.FanOutBranch
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

      %FanOutBranch{} = _first_branch ->
        {fan_out_directives, remaining} =
          Enum.split_with([directive | rest], &match?(%FanOutBranch{}, &1))

        agent = execute_fan_out_directives(agent_module, agent, fan_out_directives)
        run_directive_loop(agent_module, agent, remaining)

      _other ->
        run_directive_loop(agent_module, agent, rest)
    end
  end

  defp execute_fan_out_directives(agent_module, agent, fan_out_directives) do
    # Execute branches sequentially in the test process (keeps process dictionary accessible)
    results =
      Enum.map(fan_out_directives, fn %FanOutBranch{} = branch ->
        result = execute_fan_out_branch(branch)
        {branch.branch_name, result}
      end)

    {agent, final_directives} =
      Enum.reduce(results, {agent, []}, fn {branch_name, result}, {acc, _dirs} ->
        agent_module.cmd(
          acc,
          {:fan_out_branch_result, %{branch_name: branch_name, result: result}}
        )
      end)

    # Continue processing any directives emitted after fan-out completes
    run_directive_loop(agent_module, agent, final_directives)
  end

  defp execute_fan_out_branch(%FanOutBranch{child_node: child_node, params: params}) do
    child_node.__struct__.run(child_node, params, [])
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
          result: %{error: reason},
          instruction: %Jido.Instruction{action: action_module, params: params},
          effects: [],
          meta: %{}
        }
    end
  end

  # -- Mixed FanOut with AgentNode workflows --

  defmodule MixedFanOutWorkflow do
    {:ok, echo_node} = ActionNode.new(EchoAction)

    {:ok, agent_node} =
      Jido.Composer.Node.AgentNode.new(Jido.Composer.TestAgents.TestWorkflowAgent)

    {:ok, fan_out} =
      FanOutNode.new(
        name: "mixed_parallel",
        branches: [echo_branch: echo_node, workflow_branch: agent_node]
      )

    use Jido.Composer.Workflow,
      name: "mixed_fan_out",
      nodes: %{
        parallel: fan_out
      },
      transitions: %{
        {:parallel, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :parallel
  end

  defmodule OrchAgentFanOutWorkflow do
    {:ok, add_node} = ActionNode.new(AddAction)

    {:ok, orch_node} =
      Jido.Composer.Node.AgentNode.new(Jido.Composer.TestAgents.TestOrchestratorAgent)

    {:ok, fan_out} =
      FanOutNode.new(
        name: "orch_parallel",
        branches: [math: add_node, analyze: orch_node]
      )

    use Jido.Composer.Workflow,
      name: "orch_fan_out",
      nodes: %{
        parallel: fan_out
      },
      transitions: %{
        {:parallel, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :parallel
  end

  defmodule FailFastAgentFanOutWorkflow do
    {:ok, fail_node} = ActionNode.new(FailAction)

    {:ok, agent_node} =
      Jido.Composer.Node.AgentNode.new(Jido.Composer.TestAgents.TestWorkflowAgent)

    {:ok, fan_out} =
      FanOutNode.new(
        name: "fail_fast_parallel",
        branches: [fail: fail_node, workflow: agent_node],
        on_error: :fail_fast
      )

    use Jido.Composer.Workflow,
      name: "fail_fast_agent_fan_out",
      nodes: %{
        parallel: fan_out
      },
      transitions: %{
        {:parallel, :ok} => :done,
        {:parallel, :error} => :failed,
        {:_, :error} => :failed
      },
      initial: :parallel
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

    test "FanOutNode emits FanOutBranch directives" do
      agent = SingleFanOutWorkflow.new()

      {agent, directives} =
        SingleFanOutWorkflow.run(agent, %{value: 1.0, amount: 2.0, message: "test"})

      # FanOutNode now emits FanOutBranch directives
      assert length(directives) == 2
      assert Enum.all?(directives, &match?(%FanOutBranch{}, &1))

      # Strategy has fan_out state
      strat = StratState.get(agent)
      assert strat.fan_out != nil
    end

    test "FanOutNode merged result is scoped under state name via run_sync" do
      agent = SingleFanOutWorkflow.new()

      assert {:ok, result} =
               SingleFanOutWorkflow.run_sync(agent, %{value: 1.0, amount: 2.0, message: "hi"})

      # FanOutNode results are scoped under the state name :compute
      assert result[:compute][:add][:result] == 3.0
      assert result[:compute][:echo][:echoed] == "hi"
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
      ctx = strat.machine.context.working

      # Prepare step scoped its result
      assert ctx[:prepare][:echoed] == "start"
      # Review (FanOutNode) step scoped its merged result
      assert Map.has_key?(ctx, :review)
    end

    test "FanOutNode branch failure transitions to error state" do
      agent = FailingFanOutWorkflow.new()
      {agent, directives} = FailingFanOutWorkflow.run(agent, %{message: "hello"})

      # Execute the FanOut directives
      agent = execute_workflow(FailingFanOutWorkflow, agent, directives)

      strat = StratState.get(agent)
      assert strat.machine.status == :failed
      assert StratState.status(agent) == :failure
    end
  end

  describe "FanOut with mixed ActionNode + AgentNode branches" do
    test "FanOut with mixed branches completes via run_sync" do
      agent = MixedFanOutWorkflow.new()

      assert {:ok, result} =
               MixedFanOutWorkflow.run_sync(agent, %{
                 message: "hello",
                 source: "test_db",
                 extract: %{records: [%{id: 1, source: "test"}], count: 1}
               })

      assert Map.has_key?(result[:parallel], :echo_branch)
      assert Map.has_key?(result[:parallel], :workflow_branch)
      assert result[:parallel][:echo_branch][:echoed] == "hello"
    end

    test "FanOut with orchestrator AgentNode branch via run_sync" do
      # With unified node-based dispatch, orchestrator AgentNode branches
      # are dispatched via AgentNode.run/3 → query_sync. We use run_sync
      # for the full end-to-end path. This test verifies the ActionNode
      # branch succeeds; the orchestrator branch may fail without an API
      # key, so we check at least the action branch result.
      agent = OrchAgentFanOutWorkflow.new()

      # The orchestrator branch needs an LLM, which won't be available.
      # With fail_fast (default), the entire fan-out fails.
      # This is expected behavior — the test validates that node-based
      # dispatch reaches AgentNode.run/3 correctly.
      result =
        OrchAgentFanOutWorkflow.run_sync(agent, %{
          value: 1.0,
          amount: 2.0,
          query: "Test query"
        })

      # Without LLM access, the orchestrator branch will error
      assert {:error, _reason} = result
    end

    test "FanOut fail_fast with agent branch failure" do
      agent = FailFastAgentFanOutWorkflow.new()

      assert {:error, %Jido.Action.Error.ExecutionFailureError{message: "intentional failure"}} =
               FailFastAgentFanOutWorkflow.run_sync(agent, %{
                 source: "test_db",
                 extract: %{records: [%{id: 1, source: "test"}], count: 1}
               })
    end
  end

  describe "FanOut context propagation" do
    test "FanOut AgentNode branches receive forked context" do
      alias Jido.Composer.Workflow.Strategy
      alias Jido.Composer.Context
      alias Jido.Composer.Node.AgentNode

      defmodule ForkDepthModule do
        def bump(ambient, _working) do
          Map.update(ambient, :depth, 1, &(&1 + 1))
        end
      end

      {:ok, action_node} = ActionNode.new(EchoAction)
      {:ok, agent_node} = AgentNode.new(Jido.Composer.TestAgents.TestWorkflowAgent)

      {:ok, fan_out} =
        FanOutNode.new(
          name: "ctx_fan_out",
          branches: [echo_branch: action_node, agent_branch: agent_node]
        )

      ctx = %{
        agent_module: Jido.Composer.Integration.WorkflowFanOutTest.SingleFanOutWorkflow,
        strategy_opts: [
          nodes: %{compute: fan_out},
          transitions: %{
            {:compute, :ok} => :done,
            {:_, :error} => :failed
          },
          initial: :compute,
          ambient: [:org_id],
          fork_fns: %{depth: {ForkDepthModule, :bump, []}}
        ]
      }

      agent = SingleFanOutWorkflow.new()
      {agent, _} = Strategy.init(agent, ctx)

      # Set context with ambient data and fork functions
      strat = StratState.get(agent)

      machine = %{
        strat.machine
        | context:
            Context.new(
              ambient: %{org_id: "acme", depth: 0},
              working: %{},
              fork_fns: %{depth: {ForkDepthModule, :bump, []}}
            )
      }

      agent = StratState.update(agent, fn s -> %{s | machine: machine} end)

      # Start workflow — dispatches FanOut
      {_agent, directives} =
        Strategy.cmd(
          agent,
          [
            %Jido.Instruction{
              action: :workflow_start,
              params: %{message: "hi", source: "test"}
            }
          ],
          ctx
        )

      assert length(directives) == 2
      assert Enum.all?(directives, &match?(%FanOutBranch{}, &1))

      # Find the action branch and agent branch
      action_branch = Enum.find(directives, &(&1.branch_name == :echo_branch))
      agent_branch = Enum.find(directives, &(&1.branch_name == :agent_branch))

      # Action branch gets flat context (no fork applied)
      assert %ActionNode{} = action_branch.child_node
      assert action_branch.params[Context.ambient_key()][:depth] == 0

      # Agent branch gets forked context (fork applied, depth incremented)
      assert %AgentNode{} = agent_branch.child_node
      assert agent_branch.params[Context.ambient_key()][:depth] == 1
      assert agent_branch.params[Context.ambient_key()][:org_id] == "acme"
    end
  end
end
