defmodule Jido.Composer.Orchestrator.StrategyTest do
  use ExUnit.Case, async: true

  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.Composer.Context
  alias Jido.Composer.NodeIO
  alias Jido.Composer.Orchestrator.Strategy
  alias Jido.Composer.TestActions.{AddAction, EchoAction}
  alias Jido.Composer.TestSupport.LLMStub

  defmodule TestOrchestratorAgent do
    use Jido.Agent,
      name: "test_orchestrator",
      description: "Test agent for orchestrator strategy tests",
      schema: []
  end

  defp init_agent(opts \\ []) do
    nodes = Keyword.get(opts, :nodes, [AddAction, EchoAction])
    extra = Keyword.drop(opts, [:nodes])

    strategy_opts =
      [
        nodes: nodes,
        model: "stub:test-model",
        system_prompt: Keyword.get(opts, :system_prompt, "You are a test assistant."),
        max_iterations: Keyword.get(opts, :max_iterations, 10),
        req_options: []
      ] ++ Keyword.drop(extra, [:system_prompt, :max_iterations])

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
      assert state.system_prompt == "You are a test assistant."
      assert state.max_iterations == 10
      assert state.iteration == 0
      assert state.conversation == nil
      assert %Context{} = state.context
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
      LLMStub.setup([{:final_answer, "Hello world!"}])
      agent = init_agent()

      {agent, directives} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, %{query: "Hi"})], ctx())

      # Strategy emits RunInstruction for LLM call
      assert length(directives) == 1
      directive = hd(directives)
      assert %Jido.Agent.Directive.RunInstruction{} = directive
      assert directive.result_action == :orchestrator_llm_result

      # Simulate runtime executing the LLM call and returning result
      llm_result = execute_llm_directive(directive)

      {agent, directives} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_llm_result, llm_result)], ctx())

      state = get_state(agent)
      assert state.status == :completed
      assert %NodeIO{type: :text, value: "Hello world!"} = state.result
      assert directives == []
    end

    test "stores query in state" do
      LLMStub.setup([{:final_answer, "OK"}])
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
      LLMStub.setup([{:tool_calls, [tool_call]}])
      agent = init_agent()

      # Start
      {agent, [llm_directive]} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, %{query: "Add 5+3"})], ctx())

      llm_result = execute_llm_directive(llm_directive)

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

      LLMStub.setup([{:tool_calls, calls}])
      agent = init_agent()

      {agent, [llm_directive]} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, %{query: "Do things"})], ctx())

      llm_result = execute_llm_directive(llm_directive)

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

      LLMStub.setup([
        {:tool_calls, [tool_call]},
        {:final_answer, "The result is 8.0"}
      ])

      agent = init_agent()

      # Start -> LLM call
      {agent, [llm_directive]} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, %{query: "Add 5+3"})], ctx())

      llm_result = execute_llm_directive(llm_directive)

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

      LLMStub.setup([
        {:tool_calls, calls},
        {:final_answer, "Done"}
      ])

      agent = init_agent()

      # Start -> LLM call
      {agent, [llm_directive]} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, %{query: "Do"})], ctx())

      llm_result = execute_llm_directive(llm_directive)

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

      LLMStub.setup([
        {:tool_calls, [tool_call]},
        {:tool_calls, [tool_call]},
        {:tool_calls, [tool_call]}
      ])

      agent = init_agent(max_iterations: 2)

      # Start -> LLM call
      {agent, [llm_dir]} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, %{query: "loop"})], ctx())

      llm_result = execute_llm_directive(llm_dir)

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

      llm_result2 = execute_llm_directive(llm_dir2)

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

      LLMStub.setup([
        {:tool_calls, [tool_call]},
        {:final_answer, "8.0"}
      ])

      agent = init_agent()

      {agent, [llm_dir]} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, %{query: "Add"})], ctx())

      llm_result = execute_llm_directive(llm_dir)

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
      assert state.context.working == %{add: %{result: 8.0}}
    end
  end

  describe "dynamic approval_policy" do
    test "approval_policy function gates tool calls dynamically" do
      tool_call = %{id: "call_1", name: "add", arguments: %{"value" => 100.0, "amount" => 50.0}}
      LLMStub.setup([{:tool_calls, [tool_call]}])

      # Policy: require approval when amount > 10
      policy = fn call, _context ->
        amount = call.arguments["amount"] || call.arguments[:amount] || 0
        if amount > 10, do: :require_approval, else: :proceed
      end

      strategy_opts = [
        nodes: [AddAction, EchoAction],
        model: "stub:test-model",
        system_prompt: "test",
        max_iterations: 10,
        req_options: [],
        approval_policy: policy
      ]

      agent = TestOrchestratorAgent.new()
      ctx = %{strategy_opts: strategy_opts}
      {agent, _} = Strategy.init(agent, ctx)

      {agent, [llm_dir]} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, %{query: "Add big"})], ctx())

      llm_result = execute_llm_directive(llm_dir)

      {agent, directives} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_llm_result, llm_result)], ctx())

      state = get_state(agent)
      # Should be gated by the dynamic policy
      assert state.status in [:awaiting_approval, :awaiting_tools_and_approval]
      # Should have a SuspendForHuman directive
      suspend_directives =
        Enum.filter(directives, &match?(%Jido.Composer.Directive.Suspend{}, &1))

      assert length(suspend_directives) == 1
    end

    test "approval_policy :proceed allows tool call through" do
      tool_call = %{id: "call_1", name: "add", arguments: %{"value" => 1.0, "amount" => 1.0}}
      LLMStub.setup([{:tool_calls, [tool_call]}, {:final_answer, "2.0"}])

      # Policy: require approval when amount > 10 (this should pass through)
      policy = fn call, _context ->
        amount = call.arguments["amount"] || call.arguments[:amount] || 0
        if amount > 10, do: :require_approval, else: :proceed
      end

      strategy_opts = [
        nodes: [AddAction, EchoAction],
        model: "stub:test-model",
        system_prompt: "test",
        max_iterations: 10,
        req_options: [],
        approval_policy: policy
      ]

      agent = TestOrchestratorAgent.new()
      ctx = %{strategy_opts: strategy_opts}
      {agent, _} = Strategy.init(agent, ctx)

      {agent, [llm_dir]} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, %{query: "Add small"})], ctx())

      llm_result = execute_llm_directive(llm_dir)

      {agent, directives} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_llm_result, llm_result)], ctx())

      state = get_state(agent)
      assert state.status == :awaiting_tools
      # Should be a RunInstruction, not a SuspendForHuman
      assert Enum.all?(directives, &match?(%Jido.Agent.Directive.RunInstruction{}, &1))
    end
  end

  describe "approval rejection scopes context via scope_atom" do
    test "rejection with continue_siblings policy scopes context under tool atom" do
      # This test exercises handle_approval_rejection/4.
      # The bug: it used String.to_existing_atom(call.name) instead of scope_atom(agent, call.name).
      # scope_atom looks up from the pre-registered name_atoms map; String.to_existing_atom would
      # crash with ArgumentError for names not yet interned as atoms.
      tool_call = %{id: "call_1", name: "add", arguments: %{"value" => 10.0, "amount" => 5.0}}
      LLMStub.setup([{:tool_calls, [tool_call]}])

      strategy_opts = [
        nodes: [AddAction, EchoAction],
        model: "stub:test-model",
        system_prompt: "test",
        max_iterations: 10,
        req_options: [],
        gated_nodes: ["add"],
        rejection_policy: :continue_siblings
      ]

      agent = TestOrchestratorAgent.new()
      ctx = %{strategy_opts: strategy_opts}
      {agent, _} = Strategy.init(agent, ctx)

      # Start -> LLM call
      {agent, [llm_dir]} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, %{query: "Add"})], ctx())

      llm_result = execute_llm_directive(llm_dir)

      # LLM returns tool call -> gated
      {agent, _directives} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_llm_result, llm_result)], ctx())

      state = get_state(agent)
      assert state.status == :awaiting_approval

      # Find the request_id from gated_calls
      [{request_id, _entry}] = Map.to_list(state.gated_calls)

      # Now reject the tool call
      {agent, _directives} =
        Strategy.cmd(
          agent,
          [
            make_instruction(:hitl_response, %{
              request_id: request_id,
              decision: :rejected,
              comment: "Not allowed"
            })
          ],
          ctx()
        )

      state = get_state(agent)
      # The rejection context should be scoped under the :add atom key (via scope_atom)
      assert %{add: %{error: "REJECTED: Not allowed"}} = state.context.working
      assert state.gated_calls == %{}
    end

    test "rejection with cancel_siblings policy scopes context under tool atom" do
      tool_call = %{id: "call_1", name: "add", arguments: %{"value" => 10.0, "amount" => 5.0}}
      LLMStub.setup([{:tool_calls, [tool_call]}])

      strategy_opts = [
        nodes: [AddAction, EchoAction],
        model: "stub:test-model",
        system_prompt: "test",
        max_iterations: 10,
        req_options: [],
        gated_nodes: ["add"],
        rejection_policy: :cancel_siblings
      ]

      agent = TestOrchestratorAgent.new()
      ctx = %{strategy_opts: strategy_opts}
      {agent, _} = Strategy.init(agent, ctx)

      {agent, [llm_dir]} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, %{query: "Add"})], ctx())

      llm_result = execute_llm_directive(llm_dir)

      {agent, _directives} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_llm_result, llm_result)], ctx())

      state = get_state(agent)
      [{request_id, _entry}] = Map.to_list(state.gated_calls)

      {agent, _directives} =
        Strategy.cmd(
          agent,
          [
            make_instruction(:hitl_response, %{
              request_id: request_id,
              decision: :rejected,
              comment: "Denied"
            })
          ],
          ctx()
        )

      state = get_state(agent)
      assert %{add: %{error: "REJECTED: Denied"}} = state.context.working
      assert state.gated_calls == %{}
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

  describe "snapshot/2 with HITL" do
    test "snapshot includes HITL details when awaiting approval" do
      LLMStub.setup([
        {:tool_calls,
         [%{id: "call_1", name: "add", arguments: %{"value" => 1.0, "amount" => 2.0}}]}
      ])

      strategy_opts = [
        nodes: [AddAction, EchoAction],
        model: "stub:test-model",
        system_prompt: "test",
        max_iterations: 10,
        req_options: [],
        gated_nodes: ["add"]
      ]

      agent = TestOrchestratorAgent.new()
      ctx = %{strategy_opts: strategy_opts}
      {agent, _} = Strategy.init(agent, ctx)

      {agent, [llm_dir]} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, %{query: "Add"})], ctx())

      llm_result = execute_llm_directive(llm_dir)

      {agent, _directives} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_llm_result, llm_result)], ctx())

      snap = Strategy.snapshot(agent, ctx())
      assert snap.status == :awaiting_approval
      refute snap.done?
      assert snap.details[:reason] == :awaiting_approval
      assert is_binary(snap.details[:request_id])
    end
  end

  describe "LLM error handling" do
    test "sets error status on LLM error" do
      LLMStub.setup([{:error, "API timeout"}])
      agent = init_agent()

      {agent, [llm_dir]} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, %{query: "Hi"})], ctx())

      llm_result = execute_llm_directive(llm_dir)

      {agent, _} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_llm_result, llm_result)], ctx())

      state = get_state(agent)
      assert state.status == :error
    end
  end

  describe "NodeIO wrapping" do
    test "final answer wraps as NodeIO.text" do
      LLMStub.setup([{:final_answer, "The answer is 42"}])
      agent = init_agent()

      {agent, [llm_directive]} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, %{query: "What?"})], ctx())

      llm_result = execute_llm_directive(llm_directive)

      {agent, _} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_llm_result, llm_result)], ctx())

      state = get_state(agent)
      assert state.status == :completed
      assert %NodeIO{type: :text, value: "The answer is 42"} = state.result
    end
  end

  describe "Context integration" do
    test "init/2 builds Context struct with empty fields by default" do
      agent = init_agent()
      state = get_state(agent)

      assert %Context{ambient: %{}, working: %{}, fork_fns: %{}} = state.context
    end

    test "init/2 stores ambient_keys and fork_fns from options" do
      fork_fns = %{depth: {Kernel, :put_in, []}}
      agent = init_agent(ambient: [:org_id, :trace_id], fork_fns: fork_fns)
      state = get_state(agent)

      assert state.ambient_keys == [:org_id, :trace_id]
      assert state.context.fork_fns == %{depth: {Kernel, :put_in, []}}
    end

    test "orchestrator_start extracts ambient keys from params" do
      LLMStub.setup([{:final_answer, "Done"}])
      agent = init_agent(ambient: [:org_id])

      start_params = %{query: "Hi", org_id: "acme", data: "x"}

      {agent, [llm_directive]} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, start_params)], ctx())

      state = get_state(agent)
      assert state.context.ambient == %{org_id: "acme"}
      assert state.context.working == %{data: "x"}
      assert state.query == "Hi"

      llm_result = execute_llm_directive(llm_directive)

      {agent, _} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_llm_result, llm_result)], ctx())

      assert get_state(agent).status == :completed
    end

    test "orchestrator_start inherits __ambient__ from parent" do
      LLMStub.setup([{:final_answer, "Done"}])
      agent = init_agent(ambient: [:org_id])

      start_params = %{
        query: "Hi",
        __ambient__: %{parent_trace: "abc"},
        org_id: "acme"
      }

      {agent, _} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, start_params)], ctx())

      state = get_state(agent)
      # Both inherited and local ambient should be present
      assert state.context.ambient == %{parent_trace: "abc", org_id: "acme"}
    end

    test "tool results accumulate in context.working with ambient unchanged" do
      tool_call = %{id: "call_1", name: "add", arguments: %{"value" => 5.0, "amount" => 3.0}}

      LLMStub.setup([
        {:tool_calls, [tool_call]},
        {:final_answer, "8.0"}
      ])

      agent = init_agent(ambient: [:org_id])

      start_params = %{query: "Add", org_id: "acme"}

      {agent, [llm_dir]} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, start_params)], ctx())

      llm_result = execute_llm_directive(llm_dir)

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
      assert state.context.working == %{add: %{result: 8.0}}
      assert state.context.ambient == %{org_id: "acme"}
    end

    test "ActionNode directive includes __ambient__ in params" do
      tool_call = %{id: "call_1", name: "add", arguments: %{"value" => 5.0, "amount" => 3.0}}
      LLMStub.setup([{:tool_calls, [tool_call]}])
      agent = init_agent(ambient: [:org_id])

      start_params = %{query: "Add", org_id: "acme"}

      {agent, [llm_dir]} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, start_params)], ctx())

      llm_result = execute_llm_directive(llm_dir)

      {_agent, [directive]} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_llm_result, llm_result)], ctx())

      assert %Jido.Agent.Directive.RunInstruction{instruction: instr} = directive
      assert instr.params[:__ambient__] == %{org_id: "acme"}
    end

    test "snapshot returns flat map context" do
      LLMStub.setup([{:final_answer, "Done"}])
      agent = init_agent(ambient: [:org_id])

      start_params = %{query: "Hi", org_id: "acme"}

      {agent, [llm_dir]} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, start_params)], ctx())

      llm_result = execute_llm_directive(llm_dir)

      {agent, _} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_llm_result, llm_result)], ctx())

      snap = Strategy.snapshot(agent, ctx())
      # Should be a flat map, not a Context struct
      refute match?(%Context{}, snap.details.context)
      assert is_map(snap.details.context)
      assert snap.details.context[:__ambient__] == %{org_id: "acme"}
    end

    test "backward compatible: init without ambient/fork_fns works identically" do
      tool_call = %{id: "call_1", name: "add", arguments: %{"value" => 5.0, "amount" => 3.0}}

      LLMStub.setup([
        {:tool_calls, [tool_call]},
        {:final_answer, "8.0"}
      ])

      agent = init_agent()

      {agent, [llm_dir]} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, %{query: "Add"})], ctx())

      llm_result = execute_llm_directive(llm_dir)

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
      assert state.context.working == %{add: %{result: 8.0}}
      assert state.context.ambient == %{}

      # Snapshot returns flat map with empty ambient
      snap = Strategy.snapshot(agent, ctx())
      assert snap.details.context[:__ambient__] == %{}
    end

    test "approval_policy receives flat map with __ambient__" do
      tool_call = %{id: "call_1", name: "add", arguments: %{"value" => 100.0, "amount" => 50.0}}
      LLMStub.setup([{:tool_calls, [tool_call]}])

      received_context = :ets.new(:received_context, [:set, :public])

      policy = fn _call, context ->
        :ets.insert(received_context, {:context, context})
        :proceed
      end

      agent = init_agent(ambient: [:org_id], approval_policy: policy)

      start_params = %{query: "Add big", org_id: "acme"}

      {agent, [llm_dir]} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, start_params)], ctx())

      llm_result = execute_llm_directive(llm_dir)
      Strategy.cmd(agent, [make_instruction(:orchestrator_llm_result, llm_result)], ctx())

      [{:context, ctx_received}] = :ets.lookup(received_context, :context)
      :ets.delete(received_context)

      assert ctx_received[:__ambient__] == %{org_id: "acme"}
    end
  end

  describe "persistence readiness" do
    test "strategy state is serializable via :erlang.term_to_binary" do
      LLMStub.setup([{:final_answer, "test"}])
      agent = init_agent()

      {agent, _directives} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, %{query: "Hi"})], ctx())

      # Strategy state must be serializable (no PIDs, refs, etc.)
      strat_state = get_state(agent)
      binary = :erlang.term_to_binary(strat_state)
      restored = :erlang.binary_to_term(binary)

      assert restored.status == strat_state.status
      assert restored.query == strat_state.query
      assert restored.iteration == strat_state.iteration
    end
  end

  describe "non-HITL suspension" do
    test "suspended tool call creates suspension with Suspend directive" do
      tool_call = %{id: "call_1", name: "add", arguments: %{"value" => 5.0, "amount" => 3.0}}
      LLMStub.setup([{:tool_calls, [tool_call]}])
      agent = init_agent()

      # Start -> LLM call
      {agent, [llm_dir]} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, %{query: "Add"})], ctx())

      llm_result = execute_llm_directive(llm_dir)

      # LLM returns tool call
      {agent, [tool_dir]} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_llm_result, llm_result)], ctx())

      # Simulate tool returning :suspend (e.g., rate limited)
      suspend_params = %{
        status: :suspend,
        reason: :rate_limit,
        suspension_metadata: %{timeout: 60_000},
        arguments: tool_dir.meta,
        meta: tool_dir.meta
      }

      {agent, directives} =
        Strategy.cmd(
          agent,
          [make_instruction(:orchestrator_tool_result, suspend_params)],
          ctx()
        )

      state = get_state(agent)
      assert state.status == :awaiting_suspension

      # Should emit a Suspend directive
      assert [%Jido.Composer.Directive.Suspend{suspension: suspension}] = directives
      assert suspension.reason == :rate_limit
      assert suspension.metadata.tool_name == "add"
      assert suspension.metadata.tool_call_id == "call_1"

      # suspended_calls should have the entry
      assert map_size(state.suspended_calls) == 1
      [{suspension_id, entry}] = Map.to_list(state.suspended_calls)
      assert entry.call.id == "call_1"
      assert entry.call.name == "add"
      assert suspension_id == suspension.id
    end

    test "resume with data continues ReAct loop" do
      tool_call = %{id: "call_1", name: "add", arguments: %{"value" => 5.0, "amount" => 3.0}}

      LLMStub.setup([
        {:tool_calls, [tool_call]},
        {:final_answer, "The result is 8.0"}
      ])

      agent = init_agent()

      # Start -> LLM call
      {agent, [llm_dir]} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_start, %{query: "Add 5+3"})], ctx())

      llm_result = execute_llm_directive(llm_dir)

      # LLM returns tool call
      {agent, [tool_dir]} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_llm_result, llm_result)], ctx())

      # Tool suspends (rate limited)
      suspend_params = %{
        status: :suspend,
        reason: :rate_limit,
        suspension_metadata: %{},
        arguments: tool_dir.meta,
        meta: tool_dir.meta
      }

      {agent, [%Jido.Composer.Directive.Suspend{suspension: suspension}]} =
        Strategy.cmd(
          agent,
          [make_instruction(:orchestrator_tool_result, suspend_params)],
          ctx()
        )

      state = get_state(agent)
      assert state.status == :awaiting_suspension

      # Resume with data — provides the tool result directly
      resume_params = %{
        suspension_id: suspension.id,
        outcome: :ok,
        data: %{result: 8.0}
      }

      {agent, directives} =
        Strategy.cmd(agent, [make_instruction(:suspend_resume, resume_params)], ctx())

      # Should trigger next LLM call (ReAct loop continues)
      assert [%Jido.Agent.Directive.RunInstruction{} = llm_dir2] = directives
      assert llm_dir2.result_action == :orchestrator_llm_result

      state = get_state(agent)
      assert state.status == :awaiting_llm
      assert state.suspended_calls == %{}
      assert state.context.working == %{add: %{result: 8.0}}

      # Complete the loop — LLM returns final answer
      llm_result2 = execute_llm_directive(llm_dir2)

      {agent, []} =
        Strategy.cmd(agent, [make_instruction(:orchestrator_llm_result, llm_result2)], ctx())

      state = get_state(agent)
      assert state.status == :completed
      assert %NodeIO{type: :text, value: "The result is 8.0"} = state.result
    end
  end

  # Simulates what the runtime does when executing a RunInstruction for LLM
  defp execute_llm_directive(%Jido.Agent.Directive.RunInstruction{instruction: instr}) do
    result = LLMStub.execute(instr.params)

    case result do
      {:ok, %{response: response, conversation: conversation}} ->
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
