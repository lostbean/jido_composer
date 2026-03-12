defmodule Jido.Composer.Integration.OrchestratorTest do
  use ExUnit.Case, async: true

  import ReqCassette

  alias Jido.Agent.Directive
  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.Composer.CassetteHelper
  alias Jido.Composer.TestSupport.LLMStub

  # -- Orchestrator definitions --

  defmodule ToolOrchestrator do
    use Jido.Composer.Orchestrator,
      name: "tool_orchestrator",
      description: "Orchestrator for integration tests",
      nodes: [
        Jido.Composer.TestActions.AddAction,
        Jido.Composer.TestActions.EchoAction
      ],
      system_prompt: "You are a helpful assistant with math and echo tools."
  end

  defmodule BoundedOrchestrator do
    use Jido.Composer.Orchestrator,
      name: "bounded_orchestrator",
      nodes: [Jido.Composer.TestActions.EchoAction],
      max_iterations: 2
  end

  # -- Stub helpers (for edge-case tests only) --

  defp execute_orchestrator(agent_module, agent, directives) do
    run_directive_loop(agent_module, agent, directives)
  end

  defp run_directive_loop(_agent_module, agent, []), do: agent

  defp run_directive_loop(agent_module, agent, [directive | rest]) do
    case directive do
      %Directive.RunInstruction{instruction: instr, result_action: result_action, meta: meta} ->
        payload = execute_stub_instruction(instr, meta)
        {agent, new_directives} = agent_module.cmd(agent, {result_action, payload})
        run_directive_loop(agent_module, agent, new_directives ++ rest)

      _other ->
        run_directive_loop(agent_module, agent, rest)
    end
  end

  defp execute_stub_instruction(
         %Jido.Instruction{action: Jido.Composer.Orchestrator.LLMAction} = instr,
         _meta
       ) do
    case LLMStub.execute(instr.params) do
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

  defp execute_stub_instruction(%Jido.Instruction{action: action_module, params: params}, meta) do
    case Jido.Exec.run(action_module, params) do
      {:ok, result} ->
        %{status: :ok, result: result, meta: meta || %{}}

      {:error, reason} ->
        %{status: :error, result: reason, meta: meta || %{}}
    end
  end

  defmodule AmbientTermOrchestrator do
    use Jido.Composer.Orchestrator,
      name: "ambient_term_orchestrator",
      description: "Orchestrator with ambient context and termination tool",
      nodes: [
        Jido.Composer.TestActions.AddAction
      ],
      ambient: [:actor],
      termination_tool: Jido.Composer.TestActions.AmbientFinalReportAction,
      system_prompt: "You are a helpful assistant. Always call ambient_final_report to finish."
  end

  # -- Edge-case tests (stubs only — no cassette equivalent) --

  describe "tool param isolation (regression)" do
    test "sequential tool calls do not leak scoped results into subsequent tool params" do
      # First call: add(value=10, amount=5) → result scoped under :add
      # Second call: echo(message="hello") → should NOT see :add in its params
      LLMStub.setup([
        {:tool_calls,
         [%{id: "call_1", name: "add", arguments: %{"value" => 10.0, "amount" => 5.0}}]},
        {:tool_calls, [%{id: "call_2", name: "echo", arguments: %{"message" => "hello"}}]},
        {:final_answer, "Done"}
      ])

      agent = ToolOrchestrator.new()
      {agent, directives} = ToolOrchestrator.query(agent, "Do math then echo")

      # Custom loop that captures tool instruction params
      {agent, captured_params} = execute_capturing_params(ToolOrchestrator, agent, directives)

      strat = StratState.get(agent)
      assert strat.status == :completed

      # Both tools should have produced results
      assert strat.context.working[:add][:result] in [15, 15.0]
      assert strat.context.working[:echo][:echoed] == "hello"

      # The echo tool's params must NOT contain the :add scoped result
      echo_params = captured_params["call_2"]
      assert echo_params != nil, "echo tool params were not captured"
      refute Map.has_key?(echo_params, :add), "scoped result from 'add' leaked into echo params"
      assert Map.has_key?(echo_params, :message), "echo params missing its own 'message' key"
    end
  end

  defp execute_capturing_params(agent_module, agent, directives) do
    run_capturing_loop(agent_module, agent, directives, %{})
  end

  defp run_capturing_loop(_agent_module, agent, [], captured), do: {agent, captured}

  defp run_capturing_loop(agent_module, agent, [directive | rest], captured) do
    case directive do
      %Directive.RunInstruction{instruction: instr, result_action: result_action, meta: meta} ->
        # Capture tool call params (keyed by call_id from meta)
        captured =
          case meta do
            %{call_id: call_id} -> Map.put(captured, call_id, instr.params)
            _ -> captured
          end

        payload = execute_stub_instruction(instr, meta)
        {agent, new_directives} = agent_module.cmd(agent, {result_action, payload})
        run_capturing_loop(agent_module, agent, new_directives ++ rest, captured)

      _other ->
        run_capturing_loop(agent_module, agent, rest, captured)
    end
  end

  describe "max iteration limit" do
    test "halts with error when LLM keeps calling tools beyond limit" do
      loop_call = %{id: "call_loop", name: "echo", arguments: %{"message" => "loop"}}

      LLMStub.setup([
        {:tool_calls, [loop_call]},
        {:tool_calls, [loop_call]},
        {:tool_calls, [loop_call]}
      ])

      agent = BoundedOrchestrator.new()
      {agent, directives} = BoundedOrchestrator.query(agent, "Loop forever")
      agent = execute_orchestrator(BoundedOrchestrator, agent, directives)

      strat = StratState.get(agent)
      assert strat.status == :error
      assert strat.result =~ "iteration"
    end
  end

  describe "LLM error" do
    test "handles LLM generate failure gracefully" do
      LLMStub.setup([{:error, "API rate limited"}])

      agent = ToolOrchestrator.new()
      {agent, directives} = ToolOrchestrator.query(agent, "Hello")
      agent = execute_orchestrator(ToolOrchestrator, agent, directives)

      strat = StratState.get(agent)
      assert strat.status == :error
    end
  end

  # -- Cassette-driven tests using ReqLLM --

  # A bare agent for cassette tests (strategy initialized manually with req_options)
  defmodule CassetteAgent do
    use Jido.Agent,
      name: "cassette_orchestrator",
      description: "Agent for cassette-driven orchestrator tests",
      schema: []
  end

  alias Jido.Composer.Orchestrator.Strategy

  defp init_cassette_agent(plug) do
    strategy_opts = [
      nodes: [Jido.Composer.TestActions.AddAction, Jido.Composer.TestActions.EchoAction],
      model: "anthropic:claude-sonnet-4-20250514",
      system_prompt: "You are a helpful assistant with math and echo tools.",
      max_iterations: 10,
      req_options: [plug: plug]
    ]

    agent = CassetteAgent.new()
    ctx = %{strategy_opts: strategy_opts}
    {agent, _directives} = Strategy.init(agent, ctx)
    {agent, strategy_opts}
  end

  defp make_instruction(action, params) do
    %Jido.Instruction{action: action, params: params}
  end

  # Executes the full ReAct loop using LLM with cassette plug.
  # LLM calls go through LLMAction -> ReqLLM -> cassette plug -> canned response.
  # Tool calls go through Jido.Exec.run -> real action execution.
  defp execute_cassette_loop(agent, query, strategy_opts) do
    {agent, directives} =
      Strategy.cmd(agent, [make_instruction(:orchestrator_start, %{query: query})], %{})

    execute_cassette_directives(agent, directives, strategy_opts)
  end

  defp execute_cassette_directives(agent, [], _strategy_opts), do: agent

  defp execute_cassette_directives(agent, [directive | rest], strategy_opts) do
    case directive do
      %Directive.RunInstruction{
        instruction: %Jido.Instruction{action: Jido.Composer.Orchestrator.LLMAction} = instr,
        result_action: result_action
      } ->
        # Execute LLMAction directly — this calls ReqLLM which the cassette plug intercepts
        payload =
          case Jido.Composer.Orchestrator.LLMAction.run(instr.params, %{}) do
            {:ok, %{response: response, conversation: conversation}} ->
              %{
                status: :ok,
                result: %{response: response, conversation: conversation},
                meta: %{}
              }

            {:error, reason} ->
              %{status: :error, result: %{error: reason}, meta: %{}}
          end

        {agent, new_directives} =
          Strategy.cmd(agent, [make_instruction(result_action, payload)], %{})

        execute_cassette_directives(agent, new_directives ++ rest, strategy_opts)

      %Directive.RunInstruction{
        instruction: %Jido.Instruction{action: action_module, params: params},
        result_action: result_action,
        meta: meta
      } ->
        payload =
          case Jido.Exec.run(action_module, params) do
            {:ok, result} ->
              %{status: :ok, result: result, meta: meta || %{}}

            {:error, reason} ->
              %{status: :error, result: reason, meta: meta || %{}}
          end

        {agent, new_directives} =
          Strategy.cmd(agent, [make_instruction(result_action, payload)], %{})

        execute_cassette_directives(agent, new_directives ++ rest, strategy_opts)

      _other ->
        execute_cassette_directives(agent, rest, strategy_opts)
    end
  end

  describe "cassette-driven: direct final answer" do
    test "LLM answers without tool calls" do
      with_cassette(
        "orchestrator_final_answer_only",
        CassetteHelper.default_cassette_opts(),
        fn plug ->
          {agent, strategy_opts} = init_cassette_agent(plug)
          agent = execute_cassette_loop(agent, "Say hello, do not use any tools.", strategy_opts)

          strat = StratState.get(agent)
          assert strat.status == :completed
          assert is_binary(strat.result.value)
          assert String.length(strat.result.value) > 0
          assert strat.iteration == 1
          assert %Jido.Composer.Context{} = strat.context
        end
      )
    end
  end

  describe "cassette-driven: single tool call round-trip" do
    test "LLM calls add tool and returns final answer" do
      with_cassette("orchestrator_single_tool", CassetteHelper.default_cassette_opts(), fn plug ->
        {agent, strategy_opts} = init_cassette_agent(plug)
        agent = execute_cassette_loop(agent, "What is 5 + 3?", strategy_opts)

        strat = StratState.get(agent)
        assert strat.status == :completed
        assert strat.result.value =~ "8"
        assert strat.iteration >= 2

        # Tool result scoped under tool name
        assert strat.context.working[:add][:result] in [8, 8.0]

        # nodes remains a map through the full loop
        assert is_map(strat.nodes)
      end)
    end
  end

  describe "cassette-driven: multi-tool parallel" do
    test "LLM calls add and echo tools in parallel" do
      with_cassette("orchestrator_multi_tool", CassetteHelper.default_cassette_opts(), fn plug ->
        {agent, strategy_opts} = init_cassette_agent(plug)

        agent =
          execute_cassette_loop(
            agent,
            "Use the add tool with value=10.0 and amount=5.0, and use the echo tool with message='hello world'. Call both tools now.",
            strategy_opts
          )

        strat = StratState.get(agent)
        assert strat.status == :completed
        assert strat.context.working[:add][:result] in [15, 15.0]
        assert strat.context.working[:echo][:echoed] == "hello world"

        # nodes remains a map through the full loop
        assert is_map(strat.nodes)
      end)
    end
  end

  describe "cassette-driven: multi-turn conversation" do
    test "LLM makes two rounds of tool calls then final answer" do
      with_cassette("orchestrator_multi_turn", CassetteHelper.default_cassette_opts(), fn plug ->
        {agent, strategy_opts} = init_cassette_agent(plug)

        agent =
          execute_cassette_loop(
            agent,
            "First use the add tool with value=1 and amount=2. Then after you get the result, use the echo tool with message='the sum is 3'. Do these one at a time.",
            strategy_opts
          )

        strat = StratState.get(agent)
        assert strat.status == :completed
        assert strat.iteration >= 3

        # Tool results scoped correctly across turns
        assert strat.context.working[:add][:result] in [3, 3.0]
        assert strat.context.working[:echo][:echoed] == "the sum is 3"

        # Conversation built up across turns
        assert %ReqLLM.Context{} = strat.conversation
        assert length(strat.conversation.messages) > 2

        # nodes remains a map through all iterations (regression for nodes[call.name] bug)
        assert is_map(strat.nodes)
      end)
    end
  end

  describe "termination tool ambient context" do
    test "termination tool receives ambient context from orchestrator" do
      LLMStub.setup([
        {:tool_calls,
         [
           %{
             id: "call_term",
             name: "ambient_final_report",
             arguments: %{"summary" => "All done", "confidence" => 0.95}
           }
         ]}
      ])

      agent = AmbientTermOrchestrator.new()

      {agent, directives} =
        AmbientTermOrchestrator.query(agent, "Finish up", %{actor: "test_user"})

      agent = execute_orchestrator(AmbientTermOrchestrator, agent, directives)

      strat = StratState.get(agent)
      assert strat.status == :completed

      # Result should be structured (not an error)
      assert %Jido.Composer.NodeIO{type: :object, value: result} = strat.result
      assert result[:summary] == "All done"
      assert result[:confidence] == 0.95
      assert result[:actor] == "test_user"
    end
  end

  describe "snapshot" do
    test "reports idle before execution" do
      LLMStub.setup([])
      agent = ToolOrchestrator.new()
      ctx = %{agent_module: ToolOrchestrator, strategy_opts: ToolOrchestrator.strategy_opts()}
      snap = Jido.Composer.Orchestrator.Strategy.snapshot(agent, ctx)

      assert snap.status == :idle
      refute snap.done?
    end

    test "reports completed after final answer" do
      LLMStub.setup([{:final_answer, "Done"}])

      agent = ToolOrchestrator.new()
      {agent, directives} = ToolOrchestrator.query(agent, "Hi")
      agent = execute_orchestrator(ToolOrchestrator, agent, directives)

      ctx = %{agent_module: ToolOrchestrator, strategy_opts: ToolOrchestrator.strategy_opts()}
      snap = Jido.Composer.Orchestrator.Strategy.snapshot(agent, ctx)

      assert snap.status == :completed
      assert snap.done?
      assert snap.result == "Done"
      # Raw strat.result is NodeIO, but snapshot unwraps it
    end

    test "reports error after failure" do
      LLMStub.setup([{:error, "broken"}])

      agent = ToolOrchestrator.new()
      {agent, directives} = ToolOrchestrator.query(agent, "Hi")
      agent = execute_orchestrator(ToolOrchestrator, agent, directives)

      ctx = %{agent_module: ToolOrchestrator, strategy_opts: ToolOrchestrator.strategy_opts()}
      snap = Jido.Composer.Orchestrator.Strategy.snapshot(agent, ctx)

      assert snap.status == :error
      assert snap.done?
    end
  end
end
