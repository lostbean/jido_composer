defmodule Jido.Composer.Orchestrator.StrategyTest do
  use ExUnit.Case, async: true

  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.Composer.Orchestrator.Strategy
  alias Jido.Composer.TestActions.{AddAction, EchoAction}
  alias Jido.Composer.TestSupport.MockLLM

  defmodule TestOrchestratorAgent do
    use Jido.Agent,
      name: "test_orchestrator",
      description: "Test agent for orchestrator strategy tests",
      schema: []
  end

  defp init_agent(opts \\ []) do
    nodes = Keyword.get(opts, :nodes, [AddAction, EchoAction])
    max_iterations = Keyword.get(opts, :max_iterations, 10)
    system_prompt = Keyword.get(opts, :system_prompt, "You are a test assistant.")

    strategy_opts = [
      nodes: nodes,
      llm_module: MockLLM,
      system_prompt: system_prompt,
      max_iterations: max_iterations,
      req_options: []
    ]

    agent = TestOrchestratorAgent.new()
    ctx = %{strategy_opts: strategy_opts}
    {agent, _directives} = Strategy.init(agent, ctx)
    agent
  end

  defp get_state(agent), do: StratState.get(agent)

  defp make_instruction(action, params) do
    %Jido.Instruction{action: action, params: params}
  end

  defp ctx, do: %{}

  describe "init/2" do
    test "initializes strategy state with idle status" do
      agent = init_agent()
      state = get_state(agent)

      assert state.status == :idle
      assert state.llm_module == MockLLM
      assert state.system_prompt == "You are a test assistant."
      assert state.max_iterations == 10
      assert state.iteration == 0
      assert state.conversation == nil
      assert state.context == %{}
      assert state.pending_tool_calls == []
      assert state.completed_tool_results == []
      assert state.result == nil
    end

    test "builds tools from action modules" do
      agent = init_agent()
      state = get_state(agent)

      assert length(state.tools) == 2
      tool_names = Enum.map(state.tools, & &1.name)
      assert "add" in tool_names
      assert "echo" in tool_names
    end

    test "indexes nodes by name" do
      agent = init_agent()
      state = get_state(agent)

      assert Map.has_key?(state.nodes, "add")
      assert Map.has_key?(state.nodes, "echo")
    end
  end

  describe "cmd/3 :orchestrator_start" do
    test "single-turn final answer sets status to completed" do
      MockLLM.setup([{:final_answer, "Hello world!"}])
      agent = init_agent()

      {agent, directives} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, %{query: "Hi"})], ctx())

      # Strategy emits RunInstruction for LLM call
      assert length(directives) == 1
      directive = hd(directives)
      assert %Jido.Agent.Directive.RunInstruction{} = directive
      assert directive.result_action == :orchestrator_llm_result

      # Simulate runtime executing the LLM call and returning result
      llm_result = execute_llm_directive(directive, agent)

      {agent, directives} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_llm_result, llm_result)], ctx())

      state = get_state(agent)
      assert state.status == :completed
      assert state.result == "Hello world!"
      assert directives == []
    end

    test "stores query in state" do
      MockLLM.setup([{:final_answer, "OK"}])
      agent = init_agent()

      {agent, _} =
        Strategy.cmd(
          agent,
          [make_instruction(:orchestrator_start, %{query: "Test query"})],
          ctx()
        )

      state = get_state(agent)
      assert state.query == "Test query"
    end
  end

  describe "cmd/3 :orchestrator_llm_result with tool calls" do
    test "single tool call emits RunInstruction for action" do
      tool_call = %{id: "call_1", name: "add", arguments: %{"value" => 5.0, "amount" => 3.0}}
      MockLLM.setup([{:tool_calls, [tool_call]}])
      agent = init_agent()

      # Start
      {agent, [llm_directive]} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, %{query: "Add 5+3"})], ctx())

      llm_result = execute_llm_directive(llm_directive, agent)

      # LLM result with tool calls
      {agent, directives} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_llm_result, llm_result)], ctx())

      state = get_state(agent)
      assert state.status == :awaiting_tools
      assert length(directives) == 1

      directive = hd(directives)
      assert %Jido.Agent.Directive.RunInstruction{} = directive
      assert directive.result_action == :orchestrator_tool_result
      assert directive.meta.call_id == "call_1"
      assert directive.meta.tool_name == "add"
    end

    test "multiple tool calls emit multiple RunInstructions" do
      calls = [
        %{id: "call_1", name: "add", arguments: %{"value" => 1.0, "amount" => 2.0}},
        %{id: "call_2", name: "echo", arguments: %{"message" => "hello"}}
      ]

      MockLLM.setup([{:tool_calls, calls}])
      agent = init_agent()

      {agent, [llm_directive]} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, %{query: "Do things"})], ctx())

      llm_result = execute_llm_directive(llm_directive, agent)

      {_agent, directives} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_llm_result, llm_result)], ctx())

      assert length(directives) == 2

      call_ids = Enum.map(directives, & &1.meta.call_id)
      assert "call_1" in call_ids
      assert "call_2" in call_ids
    end
  end

  describe "cmd/3 :orchestrator_tool_result" do
    test "collects tool result and triggers next LLM call when all tools complete" do
      tool_call = %{id: "call_1", name: "add", arguments: %{"value" => 5.0, "amount" => 3.0}}

      MockLLM.setup([
        {:tool_calls, [tool_call]},
        {:final_answer, "The result is 8.0"}
      ])

      agent = init_agent()

      # Start -> LLM call
      {agent, [llm_directive]} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, %{query: "Add 5+3"})], ctx())

      llm_result = execute_llm_directive(llm_directive, agent)

      # LLM returns tool call
      {agent, [tool_directive]} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_llm_result, llm_result)], ctx())

      # Simulate tool execution result
      tool_result_params = %{
        status: :ok,
        result: %{result: 8.0},
        meta: tool_directive.meta
      }

      {agent, directives} =
        Strategy.cmd(
          agent,
          [make_instruction(:orchestrator_tool_result, tool_result_params)],
          ctx()
        )

      # Should trigger next LLM call
      assert length(directives) == 1
      assert %Jido.Agent.Directive.RunInstruction{} = hd(directives)
      assert hd(directives).result_action == :orchestrator_llm_result

      state = get_state(agent)
      assert state.status == :awaiting_llm
    end

    test "waits for all tool results before next LLM call" do
      calls = [
        %{id: "call_1", name: "add", arguments: %{"value" => 1.0, "amount" => 2.0}},
        %{id: "call_2", name: "echo", arguments: %{"message" => "hi"}}
      ]

      MockLLM.setup([
        {:tool_calls, calls},
        {:final_answer, "Done"}
      ])

      agent = init_agent()

      # Start -> LLM call
      {agent, [llm_directive]} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, %{query: "Do"})], ctx())

      llm_result = execute_llm_directive(llm_directive, agent)

      # LLM returns two tool calls
      {agent, [d1, d2]} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_llm_result, llm_result)], ctx())

      # First tool result — should NOT trigger next LLM call yet
      {agent, directives} =
        Strategy.cmd(
          agent,
          [
            make_instruction(:orchestrator_tool_result, %{
              status: :ok,
              result: %{result: 3.0},
              meta: d1.meta
            })
          ],
          ctx()
        )

      assert directives == []
      state = get_state(agent)
      assert state.status == :awaiting_tools

      # Second tool result — should trigger next LLM call
      {_agent, directives} =
        Strategy.cmd(
          agent,
          [
            make_instruction(:orchestrator_tool_result, %{
              status: :ok,
              result: %{echoed: "hi"},
              meta: d2.meta
            })
          ],
          ctx()
        )

      assert length(directives) == 1
      assert hd(directives).result_action == :orchestrator_llm_result
    end
  end

  describe "max iterations" do
    test "halts with error when max iterations exceeded" do
      # Set up an infinite loop of tool calls
      tool_call = %{id: "call_1", name: "echo", arguments: %{"message" => "loop"}}

      MockLLM.setup([
        {:tool_calls, [tool_call]},
        {:tool_calls, [tool_call]},
        {:tool_calls, [tool_call]}
      ])

      agent = init_agent(max_iterations: 2)

      # Start -> LLM call
      {agent, [llm_dir]} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, %{query: "loop"})], ctx())

      llm_result = execute_llm_directive(llm_dir, agent)

      # Iteration 1: LLM returns tool call
      {agent, [tool_dir]} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_llm_result, llm_result)], ctx())

      # Tool result
      {agent, [llm_dir2]} =
        Strategy.cmd(
          agent,
          [
            make_instruction(:orchestrator_tool_result, %{
              status: :ok,
              result: %{echoed: "loop"},
              meta: tool_dir.meta
            })
          ],
          ctx()
        )

      llm_result2 = execute_llm_directive(llm_dir2, agent)

      # Iteration 2: LLM returns tool call again -> should hit max
      {agent, directives} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_llm_result, llm_result2)], ctx())

      state = get_state(agent)
      assert state.status == :error
      assert state.result =~ "iteration"
      assert directives == []
    end
  end

  describe "context accumulation" do
    test "scopes tool results under tool name" do
      tool_call = %{id: "call_1", name: "add", arguments: %{"value" => 5.0, "amount" => 3.0}}

      MockLLM.setup([
        {:tool_calls, [tool_call]},
        {:final_answer, "8.0"}
      ])

      agent = init_agent()

      {agent, [llm_dir]} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, %{query: "Add"})], ctx())

      llm_result = execute_llm_directive(llm_dir, agent)

      {agent, [tool_dir]} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_llm_result, llm_result)], ctx())

      {agent, _} =
        Strategy.cmd(
          agent,
          [
            make_instruction(:orchestrator_tool_result, %{
              status: :ok,
              result: %{result: 8.0},
              meta: tool_dir.meta
            })
          ],
          ctx()
        )

      state = get_state(agent)
      assert state.context == %{add: %{result: 8.0}}
    end
  end

  describe "signal_routes/1" do
    test "returns routes for orchestrator signals" do
      routes = Strategy.signal_routes(%{})

      route_map = Map.new(routes, fn {signal, target} -> {signal, target} end)

      assert route_map["composer.orchestrator.query"] == {:strategy_cmd, :orchestrator_start}

      assert route_map["composer.orchestrator.child.result"] ==
               {:strategy_cmd, :orchestrator_child_result}

      assert route_map["jido.agent.child.started"] ==
               {:strategy_cmd, :orchestrator_child_started}

      assert route_map["jido.agent.child.exit"] == {:strategy_cmd, :orchestrator_child_exit}
    end
  end

  describe "LLM error handling" do
    test "sets error status on LLM error" do
      MockLLM.setup([{:error, "API timeout"}])
      agent = init_agent()

      {agent, [llm_dir]} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, %{query: "Hi"})], ctx())

      llm_result = execute_llm_directive(llm_dir, agent)

      {agent, _} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_llm_result, llm_result)], ctx())

      state = get_state(agent)
      assert state.status == :error
    end
  end

  # Simulates what the runtime does when executing a RunInstruction for LLM
  defp execute_llm_directive(%Jido.Agent.Directive.RunInstruction{instruction: instr}, agent) do
    state = get_state(agent)

    # The instruction's action module is the internal LLM action
    # We simulate the runtime calling it
    result =
      state.llm_module.generate(
        state.conversation,
        state.completed_tool_results,
        state.tools,
        query: state.query,
        system_prompt: state.system_prompt,
        req_options: state.req_options
      )

    case result do
      {:ok, response, conversation} ->
        %{
          status: :ok,
          result: %{response: response, conversation: conversation},
          meta: instr.context
        }

      {:error, reason} ->
        %{status: :error, result: %{error: reason}, meta: instr.context}
    end
  end
end
