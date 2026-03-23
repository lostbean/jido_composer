defmodule Jido.Composer.E2E.E2ETest do
  @moduledoc """
  End-to-end tests exercising full composition paths.

  - Workflow tests use `run_sync/2` (pure action execution, no LLM).
  - Orchestrator tests use ReqLLM with ReqCassette for recorded API responses.
  """
  use ExUnit.Case, async: true

  import ReqCassette

  alias Jido.Agent.Directive
  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.Composer.CassetteHelper
  alias Jido.Composer.HITL.ApprovalRequest
  alias Jido.Composer.Suspension
  alias Jido.Composer.Node.{ActionNode, FanOutNode, HumanNode}
  alias Jido.Composer.Orchestrator.Strategy

  alias Jido.Composer.NodeIO

  alias Jido.Composer.TestActions.{
    AddAction,
    MultiplyAction,
    EchoAction,
    ExtractAction,
    TransformAction,
    LoadAction,
    FailAction,
    FinalReportAction,
    ValidateOutcomeAction,
    NoopAction,
    AccumulatorAction
  }

  # ── Workflow definitions ──

  defmodule ETLWorkflow do
    use Jido.Composer.Workflow,
      name: "etl_pipeline",
      nodes: %{
        extract: ExtractAction,
        transform: TransformAction,
        load: LoadAction
      },
      transitions: %{
        {:extract, :ok} => :transform,
        {:transform, :ok} => :load,
        {:load, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :extract
  end

  defmodule MathWorkflow do
    use Jido.Composer.Workflow,
      name: "math_pipeline",
      nodes: %{
        add: AddAction,
        multiply: MultiplyAction
      },
      transitions: %{
        {:add, :ok} => :multiply,
        {:multiply, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :add
  end

  defmodule BranchingWorkflow do
    use Jido.Composer.Workflow,
      name: "branching_workflow",
      nodes: %{
        validate: ValidateOutcomeAction,
        process: NoopAction,
        retry_step: NoopAction,
        handle_invalid: NoopAction
      },
      transitions: %{
        {:validate, :ok} => :process,
        {:validate, :invalid} => :handle_invalid,
        {:validate, :retry} => :retry_step,
        {:process, :ok} => :done,
        {:handle_invalid, :ok} => :done,
        {:retry_step, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :validate
  end

  defmodule FanOutWorkflow do
    {:ok, add_node} = ActionNode.new(AddAction)
    {:ok, echo_node} = ActionNode.new(EchoAction)

    {:ok, fan_out} =
      FanOutNode.new(
        name: "parallel_compute",
        branches: [math: add_node, echo: echo_node]
      )

    use Jido.Composer.Workflow,
      name: "fan_out_workflow",
      nodes: %{
        parallel: fan_out,
        finalize: NoopAction
      },
      transitions: %{
        {:parallel, :ok} => :finalize,
        {:finalize, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :parallel
  end

  defmodule HITLWorkflow do
    use Jido.Composer.Workflow,
      name: "hitl_workflow",
      nodes: %{
        prepare: AccumulatorAction,
        approval: %HumanNode{
          name: "deploy_gate",
          description: "Gate deployment",
          prompt: "Approve deployment?",
          allowed_responses: [:approved, :rejected]
        },
        deploy: NoopAction
      },
      transitions: %{
        {:prepare, :ok} => :approval,
        {:approval, :approved} => :deploy,
        {:approval, :rejected} => :failed,
        {:deploy, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :prepare
  end

  defmodule FailingWorkflow do
    use Jido.Composer.Workflow,
      name: "failing_workflow",
      nodes: %{
        step: FailAction
      },
      transitions: %{
        {:step, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :step
  end

  defmodule RateLimitWorkflow do
    use Jido.Composer.Workflow,
      name: "rate_limit_workflow",
      nodes: %{
        prepare: AccumulatorAction,
        api_call: Jido.Composer.TestActions.RateLimitAction,
        finish: NoopAction
      },
      transitions: %{
        {:prepare, :ok} => :api_call,
        {:api_call, :ok} => :finish,
        {:api_call, :timeout} => :failed,
        {:finish, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :prepare
  end

  # ── Orchestrator agent (bare, for cassette-driven tests) ──

  defmodule CassetteOrchestratorAgent do
    use Jido.Agent,
      name: "e2e_cassette_orchestrator",
      description: "Agent for cassette-driven e2e orchestrator tests",
      schema: []
  end

  # ── Orchestrator helpers ──

  defp init_cassette_orchestrator(plug, opts \\ []) do
    nodes = Keyword.get(opts, :nodes, [AddAction, EchoAction])

    strategy_opts =
      [
        nodes: nodes,
        model: "anthropic:claude-sonnet-4-20250514",
        system_prompt:
          Keyword.get(
            opts,
            :system_prompt,
            "You are a helpful assistant with math and echo tools."
          ),
        max_iterations: Keyword.get(opts, :max_iterations, 10),
        req_options: [plug: plug]
      ] ++
        if(Keyword.has_key?(opts, :termination_tool),
          do: [termination_tool: opts[:termination_tool]],
          else: []
        )

    agent = CassetteOrchestratorAgent.new()
    ctx = %{strategy_opts: strategy_opts}
    {agent, _directives} = Strategy.init(agent, ctx)
    agent
  end

  defp make_instruction(action, params) do
    %Jido.Instruction{action: action, params: params}
  end

  # Full ReAct directive loop: LLM calls go through LLMAction -> ReqLLM -> cassette plug,
  # tool calls go through Jido.Exec.run for real action execution.
  defp execute_orchestrator_loop(agent, query) do
    {agent, directives} =
      Strategy.cmd(agent, [make_instruction(:orchestrator_start, %{query: query})], %{})

    run_directives(agent, directives)
  end

  defp run_directives(agent, []), do: agent

  defp run_directives(agent, [directive | rest]) do
    case directive do
      %Directive.RunInstruction{
        instruction: %Jido.Instruction{action: Jido.Composer.Orchestrator.LLMAction} = instr,
        result_action: result_action
      } ->
        payload = execute_llm_instruction(instr)

        {agent, new_directives} =
          Strategy.cmd(agent, [make_instruction(result_action, payload)], %{})

        run_directives(agent, new_directives ++ rest)

      %Directive.RunInstruction{
        instruction: %Jido.Instruction{action: action_module, params: params},
        result_action: result_action,
        meta: meta
      } ->
        payload = execute_tool_instruction(action_module, params, meta)

        {agent, new_directives} =
          Strategy.cmd(agent, [make_instruction(result_action, payload)], %{})

        run_directives(agent, new_directives ++ rest)

      _other ->
        run_directives(agent, rest)
    end
  end

  defp execute_llm_instruction(%Jido.Instruction{params: params}) do
    case Jido.Composer.Orchestrator.LLMAction.run(params, %{}) do
      {:ok, %{response: response, conversation: conversation}} ->
        %{
          status: :ok,
          result: %{response: response, conversation: conversation},
          meta: %{}
        }

      {:error, reason} ->
        %{status: :error, result: %{error: reason}, meta: %{}}
    end
  end

  defp execute_tool_instruction(action_module, params, meta) do
    case Jido.Exec.run(action_module, params) do
      {:ok, result} -> %{status: :ok, result: result, meta: meta || %{}}
      {:error, reason} -> %{status: :error, result: reason, meta: meta || %{}}
    end
  end

  # ══════════════════════════════════════════════════════════════════
  # Workflow e2e (run_sync — pure action execution, no LLM needed)
  # ══════════════════════════════════════════════════════════════════

  describe "workflow: ETL pipeline via run_sync" do
    test "three-step pipeline completes end-to-end" do
      agent = ETLWorkflow.new()
      assert {:ok, ctx} = ETLWorkflow.run_sync(agent, %{source: "test_db"})

      assert ctx[:extract][:records] != nil
      assert ctx[:transform][:records] != nil
      assert ctx[:load][:status] == :complete
    end
  end

  describe "workflow: math pipeline via run_sync" do
    test "chained add then multiply" do
      agent = MathWorkflow.new()
      assert {:ok, ctx} = MathWorkflow.run_sync(agent, %{value: 2.0, amount: 3.0})

      assert ctx[:add][:result] == 5.0
      assert ctx[:multiply][:result] == 6.0
    end
  end

  describe "workflow: custom outcome branching via run_sync" do
    test ":ok outcome routes to process step" do
      agent = BranchingWorkflow.new()
      assert {:ok, ctx} = BranchingWorkflow.run_sync(agent, %{data: "valid"})

      assert ctx[:validate][:validated] == true
      assert Map.has_key?(ctx, :process)
      refute Map.has_key?(ctx, :handle_invalid)
      refute Map.has_key?(ctx, :retry_step)
    end

    test ":invalid outcome routes to handle_invalid step" do
      agent = BranchingWorkflow.new()
      assert {:ok, ctx} = BranchingWorkflow.run_sync(agent, %{data: "invalid"})

      assert ctx[:validate][:validated] == false
      assert Map.has_key?(ctx, :handle_invalid)
      refute Map.has_key?(ctx, :process)
    end

    test ":retry outcome routes to retry_step" do
      agent = BranchingWorkflow.new()
      assert {:ok, ctx} = BranchingWorkflow.run_sync(agent, %{data: "retry"})

      assert ctx[:validate][:quality] == :unstable
      assert Map.has_key?(ctx, :retry_step)
      refute Map.has_key?(ctx, :process)
    end
  end

  describe "workflow: fan-out via run_sync" do
    test "parallel branches merge and feed into next step" do
      agent = FanOutWorkflow.new()

      assert {:ok, ctx} =
               FanOutWorkflow.run_sync(agent, %{value: 1.0, amount: 2.0, message: "hello"})

      assert ctx[:parallel][:math][:result] == 3.0
      assert ctx[:parallel][:echo][:echoed] == "hello"
      assert Map.has_key?(ctx, :finalize)
    end
  end

  describe "workflow: HITL suspend via run_sync" do
    test "returns suspended with ApprovalRequest" do
      agent = HITLWorkflow.new()

      assert {:error, {:suspended, %Suspension{reason: :human_input} = suspension}} =
               HITLWorkflow.run_sync(agent, %{tag: "v1.0"})

      assert %ApprovalRequest{} = suspension.approval_request
      assert suspension.approval_request.prompt == "Approve deployment?"
      assert suspension.approval_request.allowed_responses == [:approved, :rejected]
    end
  end

  describe "workflow: rate-limit suspension via run_sync" do
    test "returns suspended with rate_limit Suspension" do
      agent = RateLimitWorkflow.new()

      assert {:error, {:suspended, %Suspension{reason: :rate_limit} = suspension}} =
               RateLimitWorkflow.run_sync(agent, %{tag: "api-v1", tokens: 0})

      assert suspension.metadata == %{retry_after_ms: 5000}
    end
  end

  describe "workflow: error propagation via run_sync" do
    test "failing action transitions to :failed with original error" do
      agent = FailingWorkflow.new()

      assert {:error, %Jido.Action.Error.ExecutionFailureError{message: "intentional failure"}} =
               FailingWorkflow.run_sync(agent, %{})
    end

    test "raising action returns error instead of crashing" do
      defmodule RaisingWorkflow do
        use Jido.Composer.Workflow,
          name: "raising_workflow",
          nodes: %{
            step: Jido.Composer.TestActions.RaiseAction
          },
          transitions: %{
            {:step, :ok} => :done,
            {:_, :error} => :failed
          },
          initial: :step
      end

      agent = RaisingWorkflow.new()

      # Should return {:error, _} not crash
      assert {:error, reason} = RaisingWorkflow.run_sync(agent, %{})
      assert reason != :workflow_failed
    end

    test "nested workflow propagates child error to parent" do
      defmodule InnerFailingWorkflow do
        use Jido.Composer.Workflow,
          name: "inner_failing",
          nodes: %{
            step: FailAction
          },
          transitions: %{
            {:step, :ok} => :done,
            {:_, :error} => :failed
          },
          initial: :step
      end

      defmodule OuterContainerWorkflow do
        use Jido.Composer.Workflow,
          name: "outer_container",
          nodes: %{
            prepare: NoopAction,
            inner: {InnerFailingWorkflow, []}
          },
          transitions: %{
            {:prepare, :ok} => :inner,
            {:inner, :ok} => :done,
            {:_, :error} => :failed
          },
          initial: :prepare
      end

      agent = OuterContainerWorkflow.new()
      assert {:error, reason} = OuterContainerWorkflow.run_sync(agent, %{})
      # The outer workflow should propagate the inner's error, not just :workflow_failed
      assert reason != :workflow_failed
    end

    test "deeply nested workflow (3 levels) propagates error" do
      defmodule Level1FailWorkflow do
        use Jido.Composer.Workflow,
          name: "level1_fail",
          nodes: %{step: FailAction},
          transitions: %{{:step, :ok} => :done, {:_, :error} => :failed},
          initial: :step
      end

      defmodule Level2WrapperWorkflow do
        use Jido.Composer.Workflow,
          name: "level2_wrapper",
          nodes: %{inner: {Level1FailWorkflow, []}},
          transitions: %{{:inner, :ok} => :done, {:_, :error} => :failed},
          initial: :inner
      end

      defmodule Level3WrapperWorkflow do
        use Jido.Composer.Workflow,
          name: "level3_wrapper",
          nodes: %{inner: {Level2WrapperWorkflow, []}},
          transitions: %{{:inner, :ok} => :done, {:_, :error} => :failed},
          initial: :inner
      end

      agent = Level3WrapperWorkflow.new()
      assert {:error, reason} = Level3WrapperWorkflow.run_sync(agent, %{})
      # Error should propagate all the way up, not collapse to :workflow_failed
      assert reason != :workflow_failed
    end
  end

  describe "workflow: nested workflow agent via run_sync" do
    defmodule NestedWorkflowE2E do
      use Jido.Composer.Workflow,
        name: "nested_workflow_e2e",
        nodes: %{
          extract: ExtractAction,
          inner: {Jido.Composer.TestAgents.TestWorkflowAgent, []}
        },
        transitions: %{
          {:extract, :ok} => :inner,
          {:inner, :ok} => :done,
          {:_, :error} => :failed
        },
        initial: :extract
    end

    test "workflow with nested workflow agent via AgentNode.run/3" do
      agent = NestedWorkflowE2E.new()
      assert {:ok, ctx} = NestedWorkflowE2E.run_sync(agent, %{source: "e2e_db"})

      # Extract produced records
      assert ctx[:extract][:records] != nil
      # Inner workflow ran transform + load
      assert ctx[:inner][:transform][:records] != nil
      assert ctx[:inner][:load][:status] == :complete
    end
  end

  # ══════════════════════════════════════════════════════════════════
  # Orchestrator e2e (cassette-driven with ReqLLM)
  # ══════════════════════════════════════════════════════════════════

  describe "orchestrator: direct final answer (cassette)" do
    test "LLM answers without calling any tools" do
      with_cassette(
        "e2e_orchestrator_final_answer",
        CassetteHelper.default_cassette_opts(),
        fn plug ->
          agent = init_cassette_orchestrator(plug)
          agent = execute_orchestrator_loop(agent, "Say hello, do not use any tools.")

          strat = StratState.get(agent)
          assert strat.status == :completed
          assert is_binary(strat.result.value)
          assert strat.result.value != ""
          assert strat.iteration == 1
          assert %Jido.Composer.Context{} = strat.context
        end
      )
    end
  end

  describe "orchestrator: single tool call (cassette)" do
    test "LLM calls add tool and returns final answer" do
      with_cassette(
        "e2e_orchestrator_single_tool",
        CassetteHelper.default_cassette_opts(),
        fn plug ->
          agent = init_cassette_orchestrator(plug)
          agent = execute_orchestrator_loop(agent, "What is 5 + 3? Use the add tool.")

          strat = StratState.get(agent)
          assert strat.status == :completed
          assert strat.result.value =~ "8"
          assert strat.iteration >= 2
          assert strat.context.working[:add][:result] in [8, 8.0]
        end
      )
    end
  end

  describe "orchestrator: multi-tool parallel (cassette)" do
    test "LLM calls add and echo tools in parallel" do
      with_cassette(
        "e2e_orchestrator_multi_tool",
        CassetteHelper.default_cassette_opts(),
        fn plug ->
          agent = init_cassette_orchestrator(plug)

          agent =
            execute_orchestrator_loop(
              agent,
              "Use the add tool with value=10.0 and amount=5.0, and use the echo tool with message='hello world'. Call both tools now."
            )

          strat = StratState.get(agent)
          assert strat.status == :completed
          assert strat.context.working[:add][:result] in [15, 15.0]
          assert strat.context.working[:echo][:echoed] == "hello world"
        end
      )
    end
  end

  describe "orchestrator: multi-turn conversation (cassette)" do
    test "LLM makes sequential tool calls across turns" do
      with_cassette(
        "e2e_orchestrator_multi_turn",
        CassetteHelper.default_cassette_opts(),
        fn plug ->
          agent = init_cassette_orchestrator(plug)

          agent =
            execute_orchestrator_loop(
              agent,
              "First use the add tool with value=1 and amount=2. Then after you get the result, use the echo tool with message='the sum is 3'. Do these one at a time."
            )

          strat = StratState.get(agent)
          assert strat.status == :completed
          assert strat.iteration >= 3
          assert %ReqLLM.Context{} = strat.conversation
          assert length(strat.conversation.messages) > 2
        end
      )
    end
  end

  describe "workflow: nested orchestrator (cassette)" do
    defmodule NestedOrchWorkflow do
      use Jido.Composer.Workflow,
        name: "nested_orch_workflow",
        nodes: %{
          extract: ExtractAction,
          analyze: {Jido.Composer.TestAgents.TestOrchestratorAgent, []}
        },
        transitions: %{
          {:extract, :ok} => :analyze,
          {:analyze, :ok} => :done,
          {:_, :error} => :failed
        },
        initial: :extract
    end

    test "workflow with nested orchestrator completes via cassette" do
      with_cassette(
        "e2e_workflow_nested_orchestrator",
        CassetteHelper.default_cassette_opts(),
        fn plug ->
          wf_agent = NestedOrchWorkflow.new()
          {wf_agent, directives} = NestedOrchWorkflow.run(wf_agent, %{source: "cassette_db"})

          # Drive the outer workflow directive loop
          wf_agent = run_workflow_with_cassette(NestedOrchWorkflow, wf_agent, directives, plug)

          strat = StratState.get(wf_agent)
          assert strat.machine.status == :done
          assert StratState.status(wf_agent) == :success

          # Extract step produced records
          assert strat.machine.context.working[:extract][:records] != nil
          # Analyze step (orchestrator) produced a result
          assert Map.has_key?(strat.machine.context.working, :analyze)
        end
      )
    end

    defp run_workflow_with_cassette(_module, agent, [], _plug), do: agent

    defp run_workflow_with_cassette(module, agent, [directive | rest], plug) do
      case directive do
        %Directive.RunInstruction{instruction: instr, result_action: result_action} ->
          payload = execute_tool_instruction(instr.action, instr.params, %{})
          {agent, new_directives} = module.cmd(agent, {result_action, payload})
          run_workflow_with_cassette(module, agent, new_directives ++ rest, plug)

        %Directive.SpawnAgent{agent: child_module, tag: tag, opts: spawn_opts} ->
          # Drive the child orchestrator with cassette plug
          context = Map.get(spawn_opts, :context, %{})
          result = run_child_orchestrator_with_cassette(child_module, context, plug)

          {agent, new_directives} =
            module.cmd(agent, {:workflow_child_result, %{tag: tag, result: result}})

          run_workflow_with_cassette(module, agent, new_directives ++ rest, plug)

        _other ->
          run_workflow_with_cassette(module, agent, rest, plug)
      end
    end

    defp run_child_orchestrator_with_cassette(child_module, context, plug) do
      query = Map.get(context, :query, "Summarize the extracted data.")

      # Initialize the child orchestrator with cassette plug
      orch_agent =
        init_cassette_orchestrator(plug,
          nodes: child_module.strategy_opts()[:nodes] || [EchoAction],
          system_prompt:
            child_module.strategy_opts()[:system_prompt] || "You are a helpful assistant."
        )

      orch_agent = execute_orchestrator_loop(orch_agent, query)
      strat = StratState.get(orch_agent)

      case strat.status do
        :completed ->
          result =
            case strat.result do
              %Jido.Composer.NodeIO{} = io -> Jido.Composer.NodeIO.unwrap(io)
              other -> other
            end

          {:ok, %{result: result, context: strat.context}}

        _ ->
          {:error, strat.result}
      end
    end
  end

  describe "orchestrator: NodeIO text adaptation in nested composition (LLMStub)" do
    defmodule NodeIOAdaptWorkflow do
      use Jido.Composer.Workflow,
        name: "nodeio_adapt_workflow",
        nodes: %{
          extract: ExtractAction,
          analyze: {Jido.Composer.TestAgents.TestOrchestratorAgent, []}
        },
        transitions: %{
          {:extract, :ok} => :analyze,
          {:analyze, :ok} => :done,
          {:_, :error} => :failed
        },
        initial: :extract
    end

    test "nested orchestrator text result adapted to map in parent workflow" do
      alias Jido.Composer.TestSupport.LLMStub

      plug =
        LLMStub.setup_req_stub(:nodeio_adapt_test, [
          {:final_answer, "Analysis complete: data is valid."}
        ])

      wf_agent = NodeIOAdaptWorkflow.new()
      {wf_agent, directives} = NodeIOAdaptWorkflow.run(wf_agent, %{source: "nodeio_db"})

      # Drive the outer workflow
      wf_agent = run_nodeio_workflow(NodeIOAdaptWorkflow, wf_agent, directives, plug)

      strat = StratState.get(wf_agent)
      assert strat.machine.status == :done
      assert StratState.status(wf_agent) == :success

      # Extract step produced records
      assert strat.machine.context.working[:extract][:records] != nil

      # Analyze step result should be present — orchestrator text output as a string (via query_sync unwrap)
      assert Map.has_key?(strat.machine.context.working, :analyze)
    end

    defp run_nodeio_workflow(_module, agent, [], _plug), do: agent

    defp run_nodeio_workflow(module, agent, [directive | rest], plug) do
      case directive do
        %Directive.RunInstruction{instruction: instr, result_action: result_action} ->
          payload = execute_tool_instruction(instr.action, instr.params, %{})
          {agent, new_directives} = module.cmd(agent, {result_action, payload})
          run_nodeio_workflow(module, agent, new_directives ++ rest, plug)

        %Directive.SpawnAgent{agent: child_module, tag: tag, opts: spawn_opts} ->
          context = Map.get(spawn_opts, :context, %{})
          result = run_child_orch_with_stub(child_module, context, plug)

          {agent, new_directives} =
            module.cmd(agent, {:workflow_child_result, %{tag: tag, result: result}})

          run_nodeio_workflow(module, agent, new_directives ++ rest, plug)

        _other ->
          run_nodeio_workflow(module, agent, rest, plug)
      end
    end

    defp run_child_orch_with_stub(child_module, context, plug) do
      query = Map.get(context, :query, "Analyze the data.")

      strategy_opts = [
        nodes: child_module.strategy_opts()[:nodes] || [EchoAction],
        model: "anthropic:claude-sonnet-4-20250514",
        system_prompt:
          child_module.strategy_opts()[:system_prompt] || "You are a helpful assistant.",
        max_iterations: 10,
        req_options: [plug: plug]
      ]

      orch_agent = Jido.Composer.E2E.E2ETest.CassetteOrchestratorAgent.new()
      ctx = %{strategy_opts: strategy_opts}
      {orch_agent, _} = Strategy.init(orch_agent, ctx)

      {orch_agent, directives} =
        Strategy.cmd(orch_agent, [make_instruction(:orchestrator_start, %{query: query})], %{})

      orch_agent = run_orch_stub_directives(orch_agent, directives)
      strat = StratState.get(orch_agent)

      case strat.status do
        :completed ->
          result =
            case strat.result do
              %Jido.Composer.NodeIO{} = io -> Jido.Composer.NodeIO.unwrap(io)
              other -> other
            end

          {:ok, %{result: result, context: strat.context}}

        _ ->
          {:error, strat.result}
      end
    end

    defp run_orch_stub_directives(agent, []), do: agent

    defp run_orch_stub_directives(agent, [directive | rest]) do
      case directive do
        %Directive.RunInstruction{
          instruction: %Jido.Instruction{action: Jido.Composer.Orchestrator.LLMAction} = instr,
          result_action: result_action
        } ->
          payload = execute_llm_instruction(instr)

          {agent, new_directives} =
            Strategy.cmd(agent, [make_instruction(result_action, payload)], %{})

          run_orch_stub_directives(agent, new_directives ++ rest)

        %Directive.RunInstruction{
          instruction: %Jido.Instruction{action: action_module, params: params},
          result_action: result_action,
          meta: meta
        } ->
          payload = execute_tool_instruction(action_module, params, meta)

          {agent, new_directives} =
            Strategy.cmd(agent, [make_instruction(result_action, payload)], %{})

          run_orch_stub_directives(agent, new_directives ++ rest)

        _other ->
          run_orch_stub_directives(agent, rest)
      end
    end
  end

  describe "orchestrator: NodeIO text adaptation (cassette)" do
    defmodule NodeIOCassetteWorkflow do
      use Jido.Composer.Workflow,
        name: "nodeio_cassette_workflow",
        nodes: %{
          extract: ExtractAction,
          analyze: {Jido.Composer.TestAgents.TestOrchestratorAgent, []}
        },
        transitions: %{
          {:extract, :ok} => :analyze,
          {:analyze, :ok} => :done,
          {:_, :error} => :failed
        },
        initial: :extract
    end

    test "nested orchestrator returns text, adapted to map in parent workflow" do
      with_cassette(
        "e2e_nodeio_text_adaptation",
        CassetteHelper.default_cassette_opts(),
        fn plug ->
          wf_agent = NodeIOCassetteWorkflow.new()

          {wf_agent, directives} =
            NodeIOCassetteWorkflow.run(wf_agent, %{source: "nodeio_cassette_db"})

          wf_agent =
            run_nodeio_cassette_workflow(NodeIOCassetteWorkflow, wf_agent, directives, plug)

          strat = StratState.get(wf_agent)
          assert strat.machine.status == :done
          assert StratState.status(wf_agent) == :success
          assert strat.machine.context.working[:extract][:records] != nil
          assert Map.has_key?(strat.machine.context.working, :analyze)
        end
      )
    end

    defp run_nodeio_cassette_workflow(_module, agent, [], _plug), do: agent

    defp run_nodeio_cassette_workflow(module, agent, [directive | rest], plug) do
      case directive do
        %Directive.RunInstruction{instruction: instr, result_action: result_action} ->
          payload = execute_tool_instruction(instr.action, instr.params, %{})
          {agent, new_directives} = module.cmd(agent, {result_action, payload})
          run_nodeio_cassette_workflow(module, agent, new_directives ++ rest, plug)

        %Directive.SpawnAgent{agent: child_module, tag: tag, opts: spawn_opts} ->
          context = Map.get(spawn_opts, :context, %{})
          result = run_child_orchestrator_with_cassette(child_module, context, plug)

          {agent, new_directives} =
            module.cmd(agent, {:workflow_child_result, %{tag: tag, result: result}})

          run_nodeio_cassette_workflow(module, agent, new_directives ++ rest, plug)

        _other ->
          run_nodeio_cassette_workflow(module, agent, rest, plug)
      end
    end
  end

  describe "context layers: multi-level nesting with ambient context flow (LLMStub)" do
    defmodule ContextForks do
      @moduledoc false
      def depth_fork(ambient, _working) do
        Map.update(ambient, :depth, 1, &(&1 + 1))
      end
    end

    defmodule InnerWorkflowAgent do
      @moduledoc false
      use Jido.Composer.Workflow,
        name: "inner_workflow",
        description: "Innermost workflow for 3-level nesting test",
        nodes: %{
          compute: AddAction
        },
        transitions: %{
          {:compute, :ok} => :done,
          {:_, :error} => :failed
        },
        initial: :compute
    end

    defmodule MiddleOrchestratorAgent do
      @moduledoc false
      use Jido.Composer.Orchestrator,
        name: "middle_orchestrator",
        description: "Middle orchestrator for 3-level nesting test",
        nodes: [EchoAction],
        system_prompt: "You have an echo tool. Use it to respond."
    end

    defmodule OuterContextWorkflow do
      @moduledoc false
      use Jido.Composer.Workflow,
        name: "outer_context_workflow",
        nodes: %{
          extract: ExtractAction,
          middle: {MiddleOrchestratorAgent, []}
        },
        transitions: %{
          {:extract, :ok} => :middle,
          {:middle, :ok} => :done,
          {:_, :error} => :failed
        },
        initial: :extract
    end

    test "three-level nesting preserves ambient context and results flow up" do
      alias Jido.Composer.Context
      alias Jido.Composer.TestSupport.LLMStub
      alias Jido.Composer.Workflow.Strategy, as: WfStrategy

      plug =
        LLMStub.setup_req_stub(:context_layers_test, [
          {:final_answer, "Ambient context test complete."}
        ])

      # Create Context with ambient and fork functions
      ctx =
        Context.new(
          ambient: %{org_id: "acme", user_id: "alice", depth: 0},
          working: %{},
          fork_fns: %{depth: {ContextForks, :depth_fork, []}}
        )

      # Manually drive the outer workflow with Context
      agent = OuterContextWorkflow.new()

      strat_ctx = %{
        agent_module: OuterContextWorkflow,
        strategy_opts: OuterContextWorkflow.strategy_opts()
      }

      {agent, _} = WfStrategy.init(agent, strat_ctx)

      # Set the machine context to our layered Context
      strat = StratState.get(agent)
      machine = %{strat.machine | context: ctx}

      agent =
        Jido.Agent.Strategy.State.update(agent, fn s -> %{s | machine: machine} end)

      # Start workflow with source param
      {agent, directives} =
        WfStrategy.cmd(
          agent,
          [%Jido.Instruction{action: :workflow_start, params: %{source: "context_test"}}],
          strat_ctx
        )

      # Execute extract (RunInstruction for ExtractAction)
      agent = run_context_directives(OuterContextWorkflow, agent, directives, plug, strat_ctx)

      strat = StratState.get(agent)
      assert strat.machine.status == :done
      assert StratState.status(agent) == :success

      # Ambient should be preserved in the outer context
      assert strat.machine.context.ambient[:org_id] == "acme"
      assert strat.machine.context.ambient[:depth] == 0

      # Working should have results from both steps
      assert strat.machine.context.working[:extract][:records] != nil
      assert Map.has_key?(strat.machine.context.working, :middle)
    end

    defp run_context_directives(_module, agent, [], _plug, _strat_ctx), do: agent

    defp run_context_directives(module, agent, [directive | rest], plug, strat_ctx) do
      case directive do
        %Directive.RunInstruction{instruction: instr, result_action: result_action} ->
          payload = execute_tool_instruction(instr.action, instr.params, %{})
          {agent, new_directives} = module.cmd(agent, {result_action, payload})
          run_context_directives(module, agent, new_directives ++ rest, plug, strat_ctx)

        %Directive.SpawnAgent{agent: child_module, tag: tag, opts: spawn_opts} ->
          context = Map.get(spawn_opts, :context, %{})

          # Verify forked ambient has incremented depth
          assert context[Jido.Composer.Context.ambient_key()][:depth] == 1
          assert context[Jido.Composer.Context.ambient_key()][:org_id] == "acme"

          result = run_child_with_context(child_module, context, plug)

          {agent, new_directives} =
            Jido.Composer.Workflow.Strategy.cmd(
              agent,
              [
                %Jido.Instruction{
                  action: :workflow_child_result,
                  params: %{tag: tag, result: result}
                }
              ],
              strat_ctx
            )

          run_context_directives(module, agent, new_directives ++ rest, plug, strat_ctx)

        _other ->
          run_context_directives(module, agent, rest, plug, strat_ctx)
      end
    end

    defp run_child_with_context(child_module, context, plug) do
      query = Map.get(context, :query, "Test ambient context.")

      strategy_opts = [
        nodes: child_module.strategy_opts()[:nodes] || [EchoAction],
        model: "anthropic:claude-sonnet-4-20250514",
        system_prompt:
          child_module.strategy_opts()[:system_prompt] || "You are a test assistant.",
        max_iterations: 10,
        req_options: [plug: plug]
      ]

      orch_agent = CassetteOrchestratorAgent.new()
      ctx = %{strategy_opts: strategy_opts}
      {orch_agent, _} = Strategy.init(orch_agent, ctx)

      {orch_agent, directives} =
        Strategy.cmd(
          orch_agent,
          [make_instruction(:orchestrator_start, %{query: query})],
          %{}
        )

      orch_agent = run_orch_context_directives(orch_agent, directives)
      strat = StratState.get(orch_agent)

      case strat.status do
        :completed ->
          result =
            case strat.result do
              %Jido.Composer.NodeIO{} = io -> Jido.Composer.NodeIO.unwrap(io)
              other -> other
            end

          {:ok, %{result: result, context: strat.context}}

        _ ->
          {:error, strat.result}
      end
    end

    defp run_orch_context_directives(agent, []), do: agent

    defp run_orch_context_directives(agent, [directive | rest]) do
      case directive do
        %Directive.RunInstruction{
          instruction: %Jido.Instruction{action: Jido.Composer.Orchestrator.LLMAction} = instr,
          result_action: result_action
        } ->
          payload = execute_llm_instruction(instr)

          {agent, new_directives} =
            Strategy.cmd(agent, [make_instruction(result_action, payload)], %{})

          run_orch_context_directives(agent, new_directives ++ rest)

        %Directive.RunInstruction{
          instruction: %Jido.Instruction{action: action_module, params: params},
          result_action: result_action,
          meta: meta
        } ->
          payload = execute_tool_instruction(action_module, params, meta)

          {agent, new_directives} =
            Strategy.cmd(agent, [make_instruction(result_action, payload)], %{})

          run_orch_context_directives(agent, new_directives ++ rest)

        _other ->
          run_orch_context_directives(agent, rest)
      end
    end
  end

  describe "context layers: ambient context with cassette" do
    defmodule ContextCassetteWorkflow do
      @moduledoc false
      use Jido.Composer.Workflow,
        name: "context_cassette_workflow",
        nodes: %{
          extract: ExtractAction,
          analyze: {Jido.Composer.TestAgents.TestOrchestratorAgent, []}
        },
        transitions: %{
          {:extract, :ok} => :analyze,
          {:analyze, :ok} => :done,
          {:_, :error} => :failed
        },
        initial: :extract,
        ambient: [:org_id]
    end

    test "ambient context preserved through workflow with nested orchestrator" do
      with_cassette(
        "e2e_context_layers_ambient",
        CassetteHelper.default_cassette_opts(),
        fn plug ->
          alias Jido.Composer.Workflow.Strategy, as: WfStrategy

          wf_agent = ContextCassetteWorkflow.new()

          {wf_agent, directives} =
            ContextCassetteWorkflow.run(wf_agent, %{
              source: "ambient_cassette_db",
              org_id: "acme-corp"
            })

          wf_agent =
            run_context_cassette_workflow(
              ContextCassetteWorkflow,
              wf_agent,
              directives,
              plug
            )

          strat = StratState.get(wf_agent)
          assert strat.machine.status == :done
          assert StratState.status(wf_agent) == :success

          # Ambient key was extracted
          assert strat.machine.context.ambient[:org_id] == "acme-corp"

          # Working results present
          assert strat.machine.context.working[:extract][:records] != nil
          assert Map.has_key?(strat.machine.context.working, :analyze)
        end
      )
    end

    defp run_context_cassette_workflow(_module, agent, [], _plug), do: agent

    defp run_context_cassette_workflow(module, agent, [directive | rest], plug) do
      case directive do
        %Directive.RunInstruction{instruction: instr, result_action: result_action} ->
          payload = execute_tool_instruction(instr.action, instr.params, %{})
          {agent, new_directives} = module.cmd(agent, {result_action, payload})
          run_context_cassette_workflow(module, agent, new_directives ++ rest, plug)

        %Directive.SpawnAgent{agent: child_module, tag: tag, opts: spawn_opts} ->
          context = Map.get(spawn_opts, :context, %{})
          result = run_child_orchestrator_with_cassette_ctx(child_module, context, plug)

          {agent, new_directives} =
            module.cmd(agent, {:workflow_child_result, %{tag: tag, result: result}})

          run_context_cassette_workflow(module, agent, new_directives ++ rest, plug)

        _other ->
          run_context_cassette_workflow(module, agent, rest, plug)
      end
    end

    defp run_child_orchestrator_with_cassette_ctx(child_module, context, plug) do
      query = Map.get(context, :query, "Summarize the extracted data.")

      strategy_opts = [
        nodes: child_module.strategy_opts()[:nodes] || [EchoAction],
        model: "anthropic:claude-sonnet-4-20250514",
        system_prompt:
          child_module.strategy_opts()[:system_prompt] || "You are a helpful assistant.",
        max_iterations: 10,
        req_options: [plug: plug]
      ]

      orch_agent = CassetteOrchestratorAgent.new()
      ctx = %{strategy_opts: strategy_opts}
      {orch_agent, _} = Strategy.init(orch_agent, ctx)

      orch_agent = execute_orchestrator_loop(orch_agent, query)
      strat = StratState.get(orch_agent)

      case strat.status do
        :completed ->
          result =
            case strat.result do
              %Jido.Composer.NodeIO{} = io -> Jido.Composer.NodeIO.unwrap(io)
              other -> other
            end

          {:ok, %{result: result, context: strat.context}}

        _ ->
          {:error, strat.result}
      end
    end
  end

  describe "workflow: FanOut with mixed agent and action branches (LLMStub)" do
    defmodule MixedFanOutE2EWorkflow do
      {:ok, add_node} = ActionNode.new(AddAction)
      {:ok, echo_node} = ActionNode.new(EchoAction)

      {:ok, agent_node} =
        Jido.Composer.Node.AgentNode.new(Jido.Composer.TestAgents.TestWorkflowAgent)

      {:ok, fan_out} =
        FanOutNode.new(
          name: "mixed_parallel",
          branches: [math: add_node, echo: echo_node, workflow: agent_node]
        )

      use Jido.Composer.Workflow,
        name: "mixed_fan_out_e2e",
        nodes: %{
          parallel: fan_out,
          finalize: NoopAction
        },
        transitions: %{
          {:parallel, :ok} => :finalize,
          {:finalize, :ok} => :done,
          {:_, :error} => :failed
        },
        initial: :parallel
    end

    test "FanOut with mixed action and agent branches via run_sync" do
      agent = MixedFanOutE2EWorkflow.new()

      assert {:ok, ctx} =
               MixedFanOutE2EWorkflow.run_sync(agent, %{
                 value: 1.0,
                 amount: 2.0,
                 message: "hello",
                 source: "e2e_db",
                 extract: %{records: [%{id: 1, source: "test"}], count: 1}
               })

      # ActionNode branches
      assert ctx[:parallel][:math][:result] == 3.0
      assert ctx[:parallel][:echo][:echoed] == "hello"

      # AgentNode branch (workflow agent)
      assert Map.has_key?(ctx[:parallel], :workflow)

      # Finalize step ran
      assert Map.has_key?(ctx, :finalize)
    end
  end

  describe "workflow: FanOut with mixed agent and action branches (cassette)" do
    defmodule FanOutCassetteWorkflow do
      {:ok, add_node} = ActionNode.new(AddAction)

      {:ok, orch_node} =
        Jido.Composer.Node.AgentNode.new(Jido.Composer.TestAgents.TestOrchestratorAgent)

      {:ok, fan_out} =
        FanOutNode.new(
          name: "cassette_parallel",
          branches: [math: add_node, analyze: orch_node]
        )

      use Jido.Composer.Workflow,
        name: "fan_out_cassette_workflow",
        nodes: %{
          parallel: fan_out,
          finalize: NoopAction
        },
        transitions: %{
          {:parallel, :ok} => :finalize,
          {:finalize, :ok} => :done,
          {:_, :error} => :failed
        },
        initial: :parallel
    end

    test "FanOut with orchestrator branch completes via cassette" do
      with_cassette(
        "e2e_fanout_mixed_agent_action",
        CassetteHelper.default_cassette_opts(),
        fn plug ->
          alias Jido.Composer.Workflow.Strategy, as: WfStrategy

          wf_agent = FanOutCassetteWorkflow.new()

          {wf_agent, directives} =
            FanOutCassetteWorkflow.run(wf_agent, %{
              value: 5.0,
              amount: 3.0,
              query: "Summarize the math results."
            })

          wf_agent =
            run_fanout_cassette_workflow(FanOutCassetteWorkflow, wf_agent, directives, plug)

          strat = StratState.get(wf_agent)
          assert strat.machine.status == :done
          assert StratState.status(wf_agent) == :success

          ctx = strat.machine.context.working
          # Math branch completed
          assert ctx[:parallel][:math][:result] == 8.0
          # Orchestrator branch completed
          assert Map.has_key?(ctx[:parallel], :analyze)
          # Finalize step ran
          assert Map.has_key?(ctx, :finalize)
        end
      )
    end

    defp run_fanout_cassette_workflow(_module, agent, [], _plug), do: agent

    defp run_fanout_cassette_workflow(module, agent, [directive | rest], plug) do
      alias Jido.Composer.Directive.FanOutBranch

      case directive do
        %Directive.RunInstruction{instruction: instr, result_action: result_action} ->
          payload = execute_tool_instruction(instr.action, instr.params, %{})
          {agent, new_directives} = module.cmd(agent, {result_action, payload})
          run_fanout_cassette_workflow(module, agent, new_directives ++ rest, plug)

        %FanOutBranch{} = _first_branch ->
          {fan_out_directives, remaining} =
            Enum.split_with([directive | rest], &match?(%FanOutBranch{}, &1))

          results =
            Enum.map(fan_out_directives, fn %FanOutBranch{} = branch ->
              result = execute_fanout_branch_cassette(branch, plug)
              {branch.branch_name, result}
            end)

          {agent, final_directives} =
            Enum.reduce(results, {agent, []}, fn {branch_name, result}, {acc, _dirs} ->
              module.cmd(
                acc,
                {:fan_out_branch_result, %{branch_name: branch_name, result: result}}
              )
            end)

          run_fanout_cassette_workflow(module, agent, final_directives ++ remaining, plug)

        _other ->
          run_fanout_cassette_workflow(module, agent, rest, plug)
      end
    end

    defp execute_fanout_branch_cassette(
           %Jido.Composer.Directive.FanOutBranch{
             child_node: %Jido.Composer.Node.AgentNode{agent_module: agent_module},
             params: params
           },
           plug
         ) do
      context = params

      cond do
        function_exported?(agent_module, :query_sync, 3) ->
          run_child_orchestrator_with_cassette_fanout(agent_module, context, plug)

        function_exported?(agent_module, :run_sync, 2) ->
          child_agent = agent_module.new()
          agent_module.run_sync(child_agent, context)

        true ->
          {:error, :agent_not_sync_runnable}
      end
    end

    defp execute_fanout_branch_cassette(
           %Jido.Composer.Directive.FanOutBranch{child_node: child_node, params: params},
           _plug
         ) do
      child_node.__struct__.run(child_node, params, [])
    end

    defp run_child_orchestrator_with_cassette_fanout(child_module, context, plug) do
      query = Map.get(context, :query, "Summarize the data.")

      strategy_opts = [
        nodes: child_module.strategy_opts()[:nodes] || [EchoAction],
        model: "anthropic:claude-sonnet-4-20250514",
        system_prompt:
          child_module.strategy_opts()[:system_prompt] || "You are a helpful assistant.",
        max_iterations: 10,
        req_options: [plug: plug]
      ]

      orch_agent = CassetteOrchestratorAgent.new()
      ctx = %{strategy_opts: strategy_opts}
      {orch_agent, _} = Strategy.init(orch_agent, ctx)

      orch_agent = execute_orchestrator_loop(orch_agent, query)
      strat = StratState.get(orch_agent)

      case strat.status do
        :completed ->
          result =
            case strat.result do
              %Jido.Composer.NodeIO{} = io -> Jido.Composer.NodeIO.unwrap(io)
              other -> other
            end

          {:ok, %{result: result, context: strat.context}}

        _ ->
          {:error, strat.result}
      end
    end
  end

  describe "orchestrator: tool error recovery (cassette)" do
    test "LLM recovers when a tool fails" do
      with_cassette(
        "e2e_orchestrator_tool_error",
        CassetteHelper.default_cassette_opts(),
        fn plug ->
          agent = init_cassette_orchestrator(plug, nodes: [FailAction, EchoAction])

          agent =
            execute_orchestrator_loop(
              agent,
              "Try the fail tool first. If it fails, use the echo tool with message='recovered' instead."
            )

          strat = StratState.get(agent)
          assert strat.status == :completed
          assert is_binary(strat.result.value)
        end
      )
    end
  end

  describe "orchestrator: termination tool (cassette)" do
    test "LLM uses tools then exits with structured result via termination tool" do
      with_cassette(
        "e2e_orchestrator_termination_tool",
        CassetteHelper.default_cassette_opts(),
        fn plug ->
          agent =
            init_cassette_orchestrator(plug,
              nodes: [AddAction, EchoAction],
              termination_tool: FinalReportAction,
              system_prompt: """
              You are a helpful assistant with math and echo tools.
              When you have computed a result, call the final_report tool with a summary string
              and a confidence float between 0.0 and 1.0. Do NOT respond with plain text.
              Always finish by calling final_report.
              """
            )

          agent =
            execute_orchestrator_loop(
              agent,
              "What is 5 + 3? Use the add tool to compute it, then call final_report with the result."
            )

          strat = StratState.get(agent)
          assert strat.status == :completed

          # Result should be a NodeIO.object (structured), not NodeIO.text
          assert %NodeIO{type: :object, value: result} = strat.result
          assert is_map(result)
          assert is_binary(result[:summary])
          assert is_float(result[:confidence]) or is_integer(result[:confidence])

          # The add tool should have been called before termination
          assert strat.iteration >= 2
        end
      )
    end
  end

  describe "persistence: full checkpoint/thaw cycle" do
    test "workflow with suspension checkpoints and resumes after thaw" do
      alias Jido.Composer.Checkpoint
      alias Jido.Composer.HITL.ApprovalResponse

      # Define a workflow with HumanNode inline
      defmodule CheckpointE2EWorkflow do
        use Jido.Composer.Workflow,
          name: "checkpoint_e2e",
          description: "E2E checkpoint/thaw test",
          nodes: %{
            process: AccumulatorAction,
            approval: %Jido.Composer.Node.HumanNode{
              name: "approval",
              description: "Approve",
              prompt: "Approve result?",
              allowed_responses: [:approved, :rejected],
              timeout: 60_000
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

      # Phase 1: Run until suspension
      agent = CheckpointE2EWorkflow.new()
      {agent, directives} = CheckpointE2EWorkflow.run(agent, %{tag: "checkpoint-test"})
      {agent, _remaining} = execute_until_suspend_e2e(CheckpointE2EWorkflow, agent, directives)

      strat = StratState.get(agent)
      assert strat.status == :waiting
      assert strat.pending_suspension != nil

      # Phase 2: Checkpoint (strip closures, serialize)
      checkpoint_data = Checkpoint.prepare_for_checkpoint(strat)
      binary = :erlang.term_to_binary(checkpoint_data, [:compressed])
      assert byte_size(binary) > 0

      # Phase 3: Simulate process death — create fresh agent
      fresh_agent = CheckpointE2EWorkflow.new()

      # Phase 4: Thaw — restore strategy state
      restored_strat = :erlang.binary_to_term(binary)
      restored_agent = StratState.put(fresh_agent, restored_strat)

      # Verify restored state
      restored = StratState.get(restored_agent)
      assert restored.status == :waiting
      assert restored.machine.status == :approval

      # Phase 5: Resume with approval
      {:ok, response} =
        ApprovalResponse.new(
          request_id: restored.pending_suspension.approval_request.id,
          decision: :approved
        )

      suspension_id = restored.pending_suspension.id

      {resumed_agent, resume_directives} =
        CheckpointE2EWorkflow.cmd(
          restored_agent,
          {:suspend_resume,
           %{suspension_id: suspension_id, response_data: Map.from_struct(response)}}
        )

      # Phase 6: Execute to completion
      {final_agent, _} =
        execute_until_suspend_e2e(CheckpointE2EWorkflow, resumed_agent, resume_directives)

      final_strat = StratState.get(final_agent)
      assert final_strat.machine.status == :done
      assert StratState.status(final_agent) == :success
    end
  end

  # Helper for e2e checkpoint test
  defp execute_until_suspend_e2e(_mod, agent, []), do: {agent, []}

  defp execute_until_suspend_e2e(mod, agent, [directive | rest]) do
    case directive do
      %Directive.RunInstruction{instruction: instr, result_action: result_action} ->
        payload =
          case Jido.Exec.run(instr.action, instr.params) do
            {:ok, result} ->
              %{status: :ok, result: result, instruction: instr, effects: [], meta: %{}}

            {:error, reason} ->
              %{
                status: :error,
                result: %{error: reason},
                instruction: instr,
                effects: [],
                meta: %{}
              }
          end

        {agent, new_directives} = mod.cmd(agent, {result_action, payload})
        execute_until_suspend_e2e(mod, agent, new_directives ++ rest)

      %Jido.Composer.Directive.Suspend{} = suspend ->
        {agent, [suspend | rest]}

      _other ->
        execute_until_suspend_e2e(mod, agent, rest)
    end
  end
end
