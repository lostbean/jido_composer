defmodule Jido.Composer.Integration.OrchestratorHITLTest do
  use ExUnit.Case, async: true

  alias Jido.Agent.Directive
  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.Composer.Directive.SuspendForHuman
  alias Jido.Composer.HITL.ApprovalResponse
  alias Jido.Composer.Orchestrator.Strategy
  alias Jido.Composer.TestSupport.MockLLM

  # -- Test agent (bare, for manual strategy init) --

  defmodule HITLOrchestratorAgent do
    use Jido.Agent,
      name: "hitl_orchestrator",
      description: "Agent for HITL orchestrator tests",
      schema: []
  end

  # -- Helpers --

  defp init_agent(opts) do
    gated_nodes = Keyword.get(opts, :gated_nodes, [])
    rejection_policy = Keyword.get(opts, :rejection_policy)

    nodes =
      Keyword.get(opts, :nodes, [
        Jido.Composer.TestActions.AddAction,
        Jido.Composer.TestActions.EchoAction
      ])

    strategy_opts =
      [
        nodes: nodes,
        llm_module: MockLLM,
        model: "mock:test-model",
        system_prompt: "You are a helpful assistant.",
        max_iterations: 10,
        gated_nodes: gated_nodes
      ] ++ if(rejection_policy, do: [rejection_policy: rejection_policy], else: [])

    agent = HITLOrchestratorAgent.new()
    ctx = %{strategy_opts: strategy_opts}
    {agent, _directives} = Strategy.init(agent, ctx)
    agent
  end

  defp make_instruction(action, params) do
    %Jido.Instruction{action: action, params: params}
  end

  defp execute_orchestrator(agent, directives) do
    run_directive_loop(agent, directives)
  end

  defp run_directive_loop(agent, []), do: {agent, []}

  defp run_directive_loop(agent, [directive | rest]) do
    case directive do
      %Directive.RunInstruction{
        instruction: %Jido.Instruction{action: Jido.Composer.Orchestrator.LLMAction} = instr,
        result_action: result_action
      } ->
        payload = execute_llm(instr)

        {agent, new_directives} =
          Strategy.cmd(agent, [make_instruction(result_action, payload)], %{})

        run_directive_loop(agent, new_directives ++ rest)

      %Directive.RunInstruction{
        instruction: %Jido.Instruction{action: action_module, params: params},
        result_action: result_action,
        meta: meta
      } ->
        payload = execute_action(action_module, params, meta)

        {agent, new_directives} =
          Strategy.cmd(agent, [make_instruction(result_action, payload)], %{})

        run_directive_loop(agent, new_directives ++ rest)

      %SuspendForHuman{} = suspend ->
        {agent, [suspend | rest]}

      _other ->
        run_directive_loop(agent, rest)
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

  defp execute_action(action_module, params, meta) do
    case Jido.Exec.run(action_module, params) do
      {:ok, result} -> %{status: :ok, result: result, meta: meta || %{}}
      {:error, reason} -> %{status: :error, result: reason, meta: meta || %{}}
    end
  end

  # -- Tests --

  describe "gated tool call" do
    test "single gated tool call suspends for approval" do
      agent = init_agent(gated_nodes: ["add"])

      tool_call = %{id: "call_1", name: "add", arguments: %{"value" => 5.0, "amount" => 3.0}}
      MockLLM.setup([{:tool_calls, [tool_call]}])

      {agent, directives} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, %{query: "Add 5+3"})], %{})

      {agent, remaining} = execute_orchestrator(agent, directives)

      # Should have a SuspendForHuman directive
      assert [%SuspendForHuman{} = suspend | _] = remaining
      assert suspend.approval_request.prompt =~ "add"

      strat = StratState.get(agent)
      assert strat.status == :awaiting_approval
      assert map_size(strat.gated_calls) == 1
    end

    test "approved gated tool call executes and continues" do
      agent = init_agent(gated_nodes: ["add"])

      tool_call = %{id: "call_1", name: "add", arguments: %{"value" => 5.0, "amount" => 3.0}}

      MockLLM.setup([
        {:tool_calls, [tool_call]},
        {:final_answer, "5 + 3 = 8.0"}
      ])

      {agent, directives} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, %{query: "Add 5+3"})], %{})

      {agent, _remaining} = execute_orchestrator(agent, directives)

      # Get the pending approval
      strat = StratState.get(agent)
      [{request_id, _}] = Map.to_list(strat.gated_calls)

      # Approve
      {:ok, response} = ApprovalResponse.new(request_id: request_id, decision: :approved)

      {agent, directives} =
        Strategy.cmd(agent, [make_instruction(:hitl_response, Map.from_struct(response))], %{})

      # Should now execute the tool and continue
      {agent, _} = execute_orchestrator(agent, directives)

      strat = StratState.get(agent)
      assert strat.status == :completed
      assert strat.result == "5 + 3 = 8.0"
      assert strat.context[:add][:result] == 8.0
    end

    test "rejected gated tool call injects synthetic result" do
      agent = init_agent(gated_nodes: ["add"])

      tool_call = %{id: "call_1", name: "add", arguments: %{"value" => 5.0, "amount" => 3.0}}

      MockLLM.setup([
        {:tool_calls, [tool_call]},
        {:final_answer, "The add tool was rejected, so I cannot compute."}
      ])

      {agent, directives} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, %{query: "Add 5+3"})], %{})

      {agent, _remaining} = execute_orchestrator(agent, directives)

      strat = StratState.get(agent)
      [{request_id, _}] = Map.to_list(strat.gated_calls)

      # Reject
      {:ok, response} =
        ApprovalResponse.new(
          request_id: request_id,
          decision: :rejected,
          comment: "Too risky"
        )

      {agent, directives} =
        Strategy.cmd(agent, [make_instruction(:hitl_response, Map.from_struct(response))], %{})

      # Should continue to LLM with synthetic rejection result
      {agent, _} = execute_orchestrator(agent, directives)

      strat = StratState.get(agent)
      assert strat.status == :completed
      assert strat.result =~ "rejected"
    end
  end

  describe "mixed gated/ungated tool calls" do
    test "ungated tools execute immediately, gated tools await approval" do
      agent = init_agent(gated_nodes: ["add"])

      calls = [
        %{id: "call_1", name: "add", arguments: %{"value" => 5.0, "amount" => 3.0}},
        %{id: "call_2", name: "echo", arguments: %{"message" => "hello"}}
      ]

      MockLLM.setup([{:tool_calls, calls}])

      {agent, directives} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, %{query: "Use both"})], %{})

      # Execute — echo should run, add should suspend
      {agent, remaining} = execute_orchestrator(agent, directives)

      strat = StratState.get(agent)

      # Echo was executed (its tool result is in completed list)
      assert strat.context[:echo][:echoed] == "hello"

      # Add is gated
      assert map_size(strat.gated_calls) == 1
      assert strat.status == :awaiting_approval

      # There should be a SuspendForHuman in remaining
      assert Enum.any?(remaining, &match?(%SuspendForHuman{}, &1))
    end

    test "mixed calls complete after approval" do
      agent = init_agent(gated_nodes: ["add"])

      calls = [
        %{id: "call_1", name: "add", arguments: %{"value" => 5.0, "amount" => 3.0}},
        %{id: "call_2", name: "echo", arguments: %{"message" => "hello"}}
      ]

      MockLLM.setup([
        {:tool_calls, calls},
        {:final_answer, "Add is 8, echo is hello"}
      ])

      {agent, directives} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, %{query: "Use both"})], %{})

      {agent, _remaining} = execute_orchestrator(agent, directives)

      # Approve the gated call
      strat = StratState.get(agent)
      [{request_id, _}] = Map.to_list(strat.gated_calls)

      {:ok, response} = ApprovalResponse.new(request_id: request_id, decision: :approved)

      {agent, directives} =
        Strategy.cmd(agent, [make_instruction(:hitl_response, Map.from_struct(response))], %{})

      {agent, _} = execute_orchestrator(agent, directives)

      strat = StratState.get(agent)
      assert strat.status == :completed
      assert strat.context[:add][:result] == 8.0
      assert strat.context[:echo][:echoed] == "hello"
    end
  end

  describe "rejection policy :cancel_siblings" do
    test "cancels in-flight tools when a gated tool is rejected" do
      agent = init_agent(gated_nodes: ["add"], rejection_policy: :cancel_siblings)

      calls = [
        %{id: "call_1", name: "add", arguments: %{"value" => 5.0, "amount" => 3.0}},
        %{id: "call_2", name: "echo", arguments: %{"message" => "hello"}}
      ]

      MockLLM.setup([
        {:tool_calls, calls},
        {:final_answer, "Handled cancellation"}
      ])

      {agent, directives} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, %{query: "Use both"})], %{})

      # Run only LLM directive, don't execute tool directives yet
      {agent, _remaining} = execute_orchestrator(agent, directives)

      strat = StratState.get(agent)
      [{request_id, _}] = Map.to_list(strat.gated_calls)

      # Reject the gated call — should cancel siblings
      {:ok, response} =
        ApprovalResponse.new(
          request_id: request_id,
          decision: :rejected,
          comment: "Cancelled"
        )

      {agent, _directives} =
        Strategy.cmd(agent, [make_instruction(:hitl_response, Map.from_struct(response))], %{})

      strat = StratState.get(agent)

      # With cancel_siblings: pending tools should be cleared and
      # synthetic results generated for all
      assert strat.pending_tool_calls == []
      # Should proceed to LLM with results (rejection + cancellation)
      assert strat.status == :awaiting_llm
      # Completed results should have entries for both tools
      assert strat.completed_tool_results != []
    end
  end

  describe "rejection policy :abort_iteration" do
    test "aborts entirely when a gated tool is rejected" do
      agent = init_agent(gated_nodes: ["add"], rejection_policy: :abort_iteration)

      calls = [
        %{id: "call_1", name: "add", arguments: %{"value" => 5.0, "amount" => 3.0}},
        %{id: "call_2", name: "echo", arguments: %{"message" => "hello"}}
      ]

      MockLLM.setup([{:tool_calls, calls}])

      {agent, directives} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, %{query: "Use both"})], %{})

      {agent, _remaining} = execute_orchestrator(agent, directives)

      strat = StratState.get(agent)
      [{request_id, _}] = Map.to_list(strat.gated_calls)

      {:ok, response} =
        ApprovalResponse.new(
          request_id: request_id,
          decision: :rejected,
          comment: "Abort"
        )

      {agent, _directives} =
        Strategy.cmd(agent, [make_instruction(:hitl_response, Map.from_struct(response))], %{})

      strat = StratState.get(agent)
      assert strat.status == :error
      assert strat.result =~ "abort"
    end
  end

  describe "ungated-only tool calls" do
    test "proceeds normally without HITL when no gated nodes" do
      agent = init_agent(gated_nodes: [])

      tool_call = %{id: "call_1", name: "add", arguments: %{"value" => 5.0, "amount" => 3.0}}

      MockLLM.setup([
        {:tool_calls, [tool_call]},
        {:final_answer, "8.0"}
      ])

      {agent, directives} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, %{query: "Add 5+3"})], %{})

      {agent, remaining} = execute_orchestrator(agent, directives)

      assert remaining == []
      strat = StratState.get(agent)
      assert strat.status == :completed
    end
  end
end
