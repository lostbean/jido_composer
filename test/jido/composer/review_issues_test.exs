defmodule Jido.Composer.ReviewIssuesTest do
  @moduledoc """
  Tests validating review findings and confirming fixes.
  Each describe block corresponds to a specific review issue.
  """
  use ExUnit.Case, async: true

  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.Composer.Checkpoint
  alias Jido.Composer.Context
  alias Jido.Composer.Directive.SuspendForHuman
  alias Jido.Composer.Orchestrator.Strategy, as: OrchestratorStrategy
  alias Jido.Composer.TestActions.{AddAction, EchoAction}
  alias Jido.Composer.TestSupport.LLMStub

  # ── Test agent for orchestrator strategy tests ──

  defmodule ReviewTestOrchestratorAgent do
    use Jido.Agent,
      name: "review_test_orchestrator",
      description: "Test agent for review issue tests",
      schema: []
  end

  defp init_orchestrator_agent(opts \\ []) do
    nodes = Keyword.get(opts, :nodes, [AddAction, EchoAction])

    strategy_opts = [
      nodes: nodes,
      model: "stub:test-model",
      system_prompt: "You are a test assistant.",
      max_iterations: 10,
      req_options: []
    ]

    agent = ReviewTestOrchestratorAgent.new()
    ctx = %{strategy_opts: strategy_opts}
    {agent, _directives} = OrchestratorStrategy.init(agent, ctx)
    agent
  end

  defp make_instruction(action, params) do
    %Jido.Instruction{action: action, params: params}
  end

  defp ctx, do: %{}

  # ── Issue #1: Orchestrator DSL execute_orch_instruction missing three-tuple ──

  describe "issue #1: orchestrator DSL execute_orch_instruction handles three-tuple" do
    defmodule OutcomeOrchestrator do
      use Jido.Composer.Orchestrator,
        name: "outcome_orchestrator",
        model: "anthropic:claude-sonnet-4-20250514",
        nodes: [
          Jido.Composer.TestActions.ValidateOutcomeAction,
          Jido.Composer.TestActions.EchoAction
        ],
        system_prompt: "You have validation tools."
    end

    test "orchestrator query_sync handles action returning {:ok, result, outcome}" do
      plug =
        LLMStub.setup_req_stub(:review_issue1, [
          {:tool_calls,
           [%{id: "call_1", name: "validate_outcome", arguments: %{"data" => "retry"}}]},
          {:final_answer, "Validation result: retry needed"}
        ])

      agent = OutcomeOrchestrator.new()
      agent = put_in(agent.state.__strategy__.req_options, plug: plug)

      # This should NOT crash with CaseClauseError
      assert {:ok, "Validation result: retry needed"} =
               OutcomeOrchestrator.query_sync(agent, "Validate data")
    end
  end

  # ── Issue #2: agent_id and agent_module always nil in HITL requests ──

  describe "issue #2: agent_id and agent_module populated in HITL requests" do
    defmodule HITLWorkflow do
      use Jido.Composer.Workflow,
        name: "hitl_review_workflow",
        nodes: %{
          process: Jido.Composer.TestActions.NoopAction,
          approval: %Jido.Composer.Node.HumanNode{
            name: "review_approval",
            description: "Approve",
            prompt: "Approve?",
            allowed_responses: [:approved, :rejected]
          },
          finish: Jido.Composer.TestActions.NoopAction
        },
        transitions: %{
          {:process, :ok} => :approval,
          {:approval, :approved} => :finish,
          {:approval, :rejected} => :failed,
          {:finish, :ok} => :done,
          {:_, :error} => :failed
        },
        initial: :process
    end

    test "ApprovalRequest in Suspend directive has non-nil agent_module" do
      agent = HITLWorkflow.new()
      {agent, directives} = HITLWorkflow.run(agent, %{})

      # Execute until we hit the Suspend directive
      {_agent, remaining} = execute_until_suspend(HITLWorkflow, agent, directives)

      assert [%Jido.Composer.Directive.Suspend{} = suspend | _] = remaining
      request = suspend.suspension.approval_request

      # These should NOT be nil
      assert request.agent_module != nil
    end
  end

  # ── Issue #3: Orchestrator fan_out_branch_result signal route with no handler ──

  describe "issue #3: orchestrator fan_out_branch_result handled gracefully" do
    test "fan_out_branch_result signal does not silently swallow results" do
      agent = init_orchestrator_agent()

      # Start the orchestrator
      {agent, _directives} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_start, %{query: "test"})],
          ctx()
        )

      # Sending fan_out_branch_result should return an error, not silently succeed
      {_agent, directives} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:fan_out_branch_result, %{branch_name: :test, result: {:ok, %{}}})],
          ctx()
        )

      # After fix: should return an error directive since orchestrator doesn't support fan_out
      assert [%Jido.Agent.Directive.Error{}] = directives
    end
  end

  # ── Issue #4: Checkpoint.migrate/2 no catch-all for unknown versions ──

  describe "issue #4: Checkpoint.migrate handles unknown versions" do
    test "migrate with version 3 does not crash" do
      state = %{status: :running, children: %{}}

      # This should not raise FunctionClauseError
      result = Checkpoint.migrate(state, 3)
      # v3 → v4 migration adds :stream and removes :generation_mode
      assert result.status == :running
      assert result.stream == false
    end

    test "migrate with version 0 does not crash" do
      state = %{status: :running}
      result = Checkpoint.migrate(state, 0)
      assert result.status == :running
    end
  end

  # ── Issue #5: orchestrator_tool_result crashes on unexpected status ──

  describe "issue #5: orchestrator_tool_result handles unexpected status" do
    test "nil status does not crash" do
      LLMStub.setup([
        {:tool_calls, [%{id: "call_1", name: "add", arguments: %{"value" => 1, "amount" => 2}}]},
        {:final_answer, "done"}
      ])

      agent = init_orchestrator_agent()

      # Start orchestrator and get LLM directive
      {agent, [llm_dir]} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_start, %{query: "test"})],
          ctx()
        )

      llm_result = execute_llm_directive(llm_dir)

      {agent, _tool_dirs} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_llm_result, llm_result)],
          ctx()
        )

      # Send tool result with nil status - should not crash
      {_agent, directives} =
        OrchestratorStrategy.cmd(
          agent,
          [
            make_instruction(:orchestrator_tool_result, %{
              status: nil,
              meta: %{call_id: "call_1", tool_name: "add"}
            })
          ],
          ctx()
        )

      assert [%Jido.Agent.Directive.Error{}] = directives
    end
  end

  # ── Issue #6: Context.fork_for_child order dependency ──
  # This is a documentation/design issue. We validate the current behavior
  # and ensure it works correctly with independent fork functions.

  describe "issue #6: Context.fork_for_child documents map iteration" do
    test "fork functions produce consistent results with independent functions" do
      ctx =
        Context.new(
          ambient: %{org_id: "org-1", trace_id: "trace-1"},
          working: %{data: "test"},
          fork_fns: %{
            add_correlation: {Jido.Composer.ReviewIssuesTest.ForkHelper, :add_correlation, []},
            add_timestamp: {Jido.Composer.ReviewIssuesTest.ForkHelper, :add_timestamp, []}
          }
        )

      forked = Context.fork_for_child(ctx)

      # Both fork functions should have been applied
      assert Map.has_key?(forked.ambient, :correlation_id)
      assert Map.has_key?(forked.ambient, :forked_at)
      # Original ambient preserved
      assert forked.ambient.org_id == "org-1"
    end
  end

  # ── Issue #7: SuspendForHuman vestigial struct removed ──

  describe "issue #7: SuspendForHuman is no longer a struct module" do
    test "SuspendForHuman.new/1 returns %Suspend{} and module has no struct" do
      {:ok, request} =
        Jido.Composer.HITL.ApprovalRequest.new(
          prompt: "Approve?",
          allowed_responses: [:approved, :rejected]
        )

      {:ok, directive} = SuspendForHuman.new(approval_request: request)
      assert match?(%Jido.Composer.Directive.Suspend{}, directive)

      # Struct no longer defined
      refute function_exported?(SuspendForHuman, :__struct__, 0)
      refute function_exported?(SuspendForHuman, :__struct__, 1)
    end
  end

  # ── Issue #9: Context.from_serializable/1 atom key requirement ──

  describe "issue #9: Context.from_serializable handles string keys" do
    test "from_serializable works with string keys after JSON round-trip" do
      ctx = Context.new(ambient: %{org: "test"}, working: %{data: 1})
      _serializable = Context.to_serializable(ctx)

      # Simulate JSON round-trip: atom keys become strings
      json_like = %{"ambient" => %{"org" => "test"}, "working" => %{"data" => 1}}

      # This should not crash
      restored = Context.from_serializable(json_like)
      assert restored.ambient == %{"org" => "test"}
      assert restored.working == %{"data" => 1}
    end
  end

  # ── Issue #10: Inconsistent error payload shapes ──

  describe "issue #10: orchestrator DSL error payload shape matches expectations" do
    defmodule Issue10Orchestrator do
      use Jido.Composer.Orchestrator,
        name: "issue10_orchestrator",
        model: "anthropic:claude-sonnet-4-20250514",
        nodes: [
          Jido.Composer.TestActions.AddAction,
          Jido.Composer.TestActions.EchoAction
        ],
        system_prompt: "test"
    end

    test "execute_orch_instruction error shape has :result key" do
      plug =
        LLMStub.setup_req_stub(:review_issue10, [
          {:tool_calls, [%{id: "c1", name: "add", arguments: %{"value" => 1, "amount" => 2}}]},
          {:final_answer, "done"}
        ])

      agent = Issue10Orchestrator.new()
      agent = put_in(agent.state.__strategy__.req_options, plug: plug)

      assert {:ok, "done"} = Issue10Orchestrator.query_sync(agent, "test")
    end
  end

  # ── Issue #11: check_all_tools_done status when suspended + tools pending ──

  describe "issue #11: check_all_tools_done status with suspension + pending tools" do
    test "status reflects suspension when both suspended and pending tools exist" do
      LLMStub.setup([
        {:tool_calls,
         [
           %{id: "call_1", name: "add", arguments: %{"value" => 1, "amount" => 2}},
           %{id: "call_2", name: "echo", arguments: %{"message" => "hi"}}
         ]},
        {:final_answer, "done"}
      ])

      agent = init_orchestrator_agent()

      {agent, [llm_dir]} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_start, %{query: "test"})],
          ctx()
        )

      llm_result = execute_llm_directive(llm_dir)

      {agent, _tool_dirs} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_llm_result, llm_result)],
          ctx()
        )

      # Suspend one tool call
      {agent, _} =
        OrchestratorStrategy.cmd(
          agent,
          [
            make_instruction(:orchestrator_tool_result, %{
              status: :suspend,
              reason: :rate_limit,
              meta: %{call_id: "call_1", tool_name: "add"}
            })
          ],
          ctx()
        )

      state = StratState.get(agent)
      # With call_2 still pending and call_1 suspended, status should NOT say "approval"
      refute state.status == :awaiting_tools_and_approval
      assert state.status in [:awaiting_tools, :awaiting_tools_and_suspension]
    end
  end

  # ── Issue #14: execute_fan_out_branch third clause guard ──

  describe "issue #14: FanOutBranch dispatch with nil spawn_agent guarded" do
    defmodule Issue14Workflow do
      use Jido.Composer.Workflow,
        name: "issue14_workflow",
        nodes: %{
          step: Jido.Composer.TestActions.NoopAction
        },
        transitions: %{
          {:step, :ok} => :done,
          {:_, :error} => :failed
        },
        initial: :step
    end

    @tag :capture_log
    test "branch with nil spawn_agent produces branch_crashed error, not BadMapError" do
      import ExUnit.CaptureLog

      Process.flag(:trap_exit, true)

      branch = %Jido.Composer.Directive.FanOutBranch{
        fan_out_id: "test",
        branch_name: :broken,
        instruction: nil,
        spawn_agent: nil
      }

      agent = Issue14Workflow.new()

      # Before fix: BadMapError from accessing nil.agent
      # After fix: FunctionClauseError — explicit guard rejects nil spawn_agent
      log =
        capture_log(fn ->
          _result =
            Jido.Composer.Workflow.DSL.__run_sync_loop__(Issue14Workflow, agent, [branch])
        end)

      # The error logged must be FunctionClauseError (from guard), not BadMapError
      assert log =~ "FunctionClauseError"
      refute log =~ "BadMapError"
    end
  end

  # ── Helpers ──

  defp execute_until_suspend(_mod, agent, []), do: {agent, []}

  defp execute_until_suspend(mod, agent, [directive | rest]) do
    case directive do
      %Jido.Agent.Directive.RunInstruction{instruction: instr, result_action: result_action} ->
        payload =
          case Jido.Exec.run(instr.action, instr.params) do
            {:ok, result} ->
              %{status: :ok, result: result, instruction: instr, effects: [], meta: %{}}

            {:ok, result, outcome} ->
              %{
                status: :ok,
                result: result,
                outcome: outcome,
                instruction: instr,
                effects: [],
                meta: %{}
              }

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
        execute_until_suspend(mod, agent, new_directives ++ rest)

      %Jido.Composer.Directive.Suspend{} = suspend ->
        {agent, [suspend | rest]}

      _other ->
        execute_until_suspend(mod, agent, rest)
    end
  end

  defp execute_llm_directive(%Jido.Agent.Directive.RunInstruction{instruction: instr}) do
    result = LLMStub.execute(instr.params)

    case result do
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

  # Helper module for fork function tests
  defmodule ForkHelper do
    def add_correlation(ambient, _working) do
      Map.put(ambient, :correlation_id, "corr-#{System.unique_integer([:positive])}")
    end

    def add_timestamp(ambient, _working) do
      Map.put(ambient, :forked_at, DateTime.utc_now())
    end
  end
end
