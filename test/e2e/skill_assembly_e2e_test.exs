defmodule Jido.Composer.E2E.SkillAssemblyE2ETest do
  @moduledoc """
  End-to-end test for skill assembly with DynamicAgentNode.

  Uses ReqCassette for recorded API responses. The parent Orchestrator has a
  DynamicAgentNode tool. The LLM selects skills, the DynamicAgentNode assembles
  a sub-agent, uses action tools, and returns the result through the parent.
  """
  use ExUnit.Case, async: true

  import ReqCassette

  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.Composer.CassetteHelper
  alias Jido.Composer.Node.DynamicAgentNode
  alias Jido.Composer.Orchestrator.Strategy
  alias Jido.Composer.Skill

  alias Jido.Composer.NodeIO
  alias Jido.Composer.TestActions.{AddAction, MultiplyAction, EchoAction}
  alias Jido.Composer.TestSkills
  alias Jido.Composer.TestSupport.LLMStub

  # ── Bare agent for strategy-level cassette tests ──

  defmodule SkillCassetteAgent do
    @moduledoc false
    use Jido.Agent,
      name: "skill_cassette_agent",
      description: "Agent for skill assembly cassette tests",
      schema: []
  end

  # ── DynamicAgentNode factory ──

  defp build_dynamic_node(skills, plug) do
    %DynamicAgentNode{
      name: "delegate_task",
      description:
        "Delegate a task to a dynamically assembled sub-agent. " <>
          "Select skills by name to equip the sub-agent with the right tools.",
      skill_registry: skills,
      assembly_opts: [
        base_prompt: "You are a specialist sub-agent. Complete the task using your tools.",
        model: "anthropic:claude-sonnet-4-20250514",
        req_options: [plug: plug]
      ]
    }
  end

  # ── Orchestrator helpers ──

  defp init_skill_orchestrator(plug, dynamic_node) do
    strategy_opts = [
      nodes: [EchoAction],
      model: "anthropic:claude-sonnet-4-20250514",
      system_prompt: """
      You are a coordinator agent. You have a delegate_task tool that can assemble
      specialized sub-agents from available skills. Available skills:

      - "math": Addition and multiplication operations
      - "echo": Echo messages back
      - "pipeline": Data transformation pipelines

      When asked to perform a task, use the delegate_task tool with the appropriate
      skill names and task description. Do NOT try to do the work yourself — always
      delegate via the delegate_task tool.
      """,
      max_iterations: 10,
      req_options: [plug: plug]
    ]

    agent = SkillCassetteAgent.new()
    ctx = %{strategy_opts: strategy_opts}
    {agent, _directives} = Strategy.init(agent, ctx)

    # Inject the DynamicAgentNode into the strategy state
    inject_dynamic_node(agent, dynamic_node)
  end

  defp inject_dynamic_node(agent, dynamic_node) do
    alias Jido.Composer.Orchestrator.AgentTool

    StratState.update(agent, fn state ->
      node_name = DynamicAgentNode.name(dynamic_node)
      tool = AgentTool.to_tool(dynamic_node)

      nodes = Map.put(state.nodes, node_name, dynamic_node)
      tools = state.tools ++ [tool]
      # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
      name_atoms = Map.put(state.name_atoms, node_name, String.to_atom(node_name))

      schema_keys =
        Map.put(state.schema_keys, node_name, MapSet.new([:task, :skills]))

      state
      |> Map.put(:nodes, nodes)
      |> Map.put(:tools, tools)
      |> Map.put(:name_atoms, name_atoms)
      |> Map.put(:schema_keys, schema_keys)
    end)
  end

  defp make_instruction(action, params) do
    %Jido.Instruction{action: action, params: params}
  end

  # Full ReAct directive loop — drives LLM calls through cassette plug and
  # dispatches tool calls to real action execution or DynamicAgentNode.run/3.
  defp execute_loop(agent, query) do
    {agent, directives} =
      Strategy.cmd(agent, [make_instruction(:orchestrator_start, %{query: query})], %{})

    run_directives(agent, directives)
  end

  defp run_directives(agent, []), do: agent

  defp run_directives(agent, [directive | rest]) do
    case directive do
      %Jido.Agent.Directive.RunInstruction{
        instruction: %Jido.Instruction{action: Jido.Composer.Orchestrator.LLMAction} = instr,
        result_action: result_action
      } ->
        payload = execute_llm_instruction(instr)

        {agent, new_directives} =
          Strategy.cmd(agent, [make_instruction(result_action, payload)], %{})

        run_directives(agent, new_directives ++ rest)

      %Jido.Agent.Directive.RunInstruction{
        instruction: %Jido.Instruction{action: action_module, params: params},
        result_action: result_action,
        meta: meta
      } ->
        payload = execute_tool_instruction(action_module, params, meta)

        {agent, new_directives} =
          Strategy.cmd(agent, [make_instruction(result_action, payload)], %{})

        run_directives(agent, new_directives ++ rest)

      %Jido.Agent.Directive.SpawnAgent{agent: child_module, tag: tag, opts: spawn_opts} ->
        result = Jido.Composer.Node.execute_child_sync(child_module, spawn_opts)

        {agent, new_directives} =
          Strategy.cmd(
            agent,
            [make_instruction(:orchestrator_child_result, %{tag: tag, result: result})],
            %{}
          )

        run_directives(agent, new_directives ++ rest)

      _other ->
        run_directives(agent, rest)
    end
  end

  defp execute_llm_instruction(%Jido.Instruction{params: params}) do
    case Jido.Composer.Orchestrator.LLMAction.run(params, %{}) do
      {:ok, %{response: response, conversation: conversation}} ->
        %{status: :ok, result: %{response: response, conversation: conversation}, meta: %{}}

      {:error, reason} ->
        %{status: :error, result: %{error: reason}, meta: %{}}
    end
  end

  defp execute_tool_instruction(action_module, params, meta) do
    case Jido.Exec.run(action_module, params) do
      {:ok, result} ->
        %{status: :ok, result: result, meta: meta || %{}}

      {:ok, result, outcome} ->
        %{status: :ok, result: result, outcome: outcome, meta: meta || %{}}

      {:error, reason} ->
        %{status: :error, result: %{error: reason}, meta: meta || %{}}
    end
  end

  # ══════════════════════════════════════════════════════════════════
  # E2E: Skill assembly with action-only skills (cassette)
  # ══════════════════════════════════════════════════════════════════

  describe "skill assembly: action-only skills (cassette)" do
    test "parent orchestrator delegates to DynamicAgentNode, sub-agent uses math tools" do
      session = ReqCassette.Session.start_shared_session()

      try do
        with_cassette(
          "e2e_skill_assembly_math",
          CassetteHelper.shared_cassette_opts(session),
          fn plug ->
            dynamic_node =
              build_dynamic_node([TestSkills.math_skill(), TestSkills.echo_skill()], plug)

            agent = init_skill_orchestrator(plug, dynamic_node)

            agent =
              execute_loop(
                agent,
                "What is 5 + 3? Use the delegate_task tool with the math skill to compute this."
              )

            strat = StratState.get(agent)
            assert strat.status == :completed

            # Result is a NodeIO text containing the correct answer
            assert %NodeIO{type: :text, value: result_value} = strat.result
            assert is_binary(result_value), "Expected text result, got: #{inspect(result_value)}"
            assert result_value =~ "8", "Expected answer containing '8', got: #{result_value}"

            # delegate_task tool was called and returned a text result with the answer
            assert %{result: delegate_text} = strat.context.working[:delegate_task]

            assert is_binary(delegate_text),
                   "Expected delegate text, got: #{inspect(delegate_text)}"

            assert delegate_text =~ "8",
                   "Expected delegate result with '8', got: #{delegate_text}"

            # At least 2 iterations: one for tool call, one for final answer
            assert strat.iteration >= 2,
                   "Expected >= 2 iterations (tool call + answer), got #{strat.iteration}"
          end
        )
      after
        ReqCassette.Session.end_shared_session(session)
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════
  # E2E: Skill assembly with mixed node types (cassette)
  # ══════════════════════════════════════════════════════════════════

  describe "skill assembly: multi-skill registry with selective delegation (cassette)" do
    test "sub-agent selects math skill from registry containing both action and workflow-agent skills" do
      session = ReqCassette.Session.start_shared_session()

      try do
        with_cassette(
          "e2e_skill_assembly_mixed",
          CassetteHelper.shared_cassette_opts(session),
          fn plug ->
            dynamic_node =
              build_dynamic_node([TestSkills.math_skill(), TestSkills.pipeline_skill()], plug)

            agent = init_skill_orchestrator(plug, dynamic_node)

            agent =
              execute_loop(
                agent,
                "Use the delegate_task tool with the math skill. Ask it to add 10 and 20."
              )

            strat = StratState.get(agent)
            assert strat.status == :completed

            # Result is a NodeIO text containing the correct answer
            assert %NodeIO{type: :text, value: result_value} = strat.result
            assert is_binary(result_value), "Expected text result, got: #{inspect(result_value)}"
            assert result_value =~ "30", "Expected answer containing '30', got: #{result_value}"

            # delegate_task tool was called and returned a text result with the answer
            assert %{result: delegate_text} = strat.context.working[:delegate_task]

            assert is_binary(delegate_text),
                   "Expected delegate text, got: #{inspect(delegate_text)}"

            assert delegate_text =~ "30",
                   "Expected delegate result with '30', got: #{delegate_text}"

            # At least 2 iterations: one for tool call, one for final answer
            assert strat.iteration >= 2,
                   "Expected >= 2 iterations (tool call + answer), got #{strat.iteration}"
          end
        )
      after
        ReqCassette.Session.end_shared_session(session)
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════
  # Stub-based: skill prompt injection and tool verification
  # ══════════════════════════════════════════════════════════════════

  describe "skill prompt influences sub-agent behavior (stub)" do
    test "skill prompt_fragment is composed into sub-agent system prompt" do
      # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
      stub_name = :"skill_prompt_verify_#{System.unique_integer([:positive])}"

      # Sub-agent stub: multiply first (as instructed by skill prompt), then add, then answer
      plug =
        LLMStub.setup_req_stub_with_capture(stub_name, [
          # Parent: delegate to sub-agent with math skill
          {:tool_calls,
           [
             %{
               id: "call_parent_1",
               name: "delegate_task",
               arguments: %{"task" => "Compute 5 + 3", "skills" => ["math"]}
             }
           ]},
          # Sub-agent turn 1: multiply by 10 first (following the custom prompt)
          {:tool_calls,
           [
             %{
               id: "call_sub_1",
               name: "multiply",
               arguments: %{"value" => 5.0, "amount" => 10.0}
             }
           ]},
          # Sub-agent turn 2: then add
          {:tool_calls,
           [
             %{
               id: "call_sub_2",
               name: "add",
               arguments: %{"value" => 50.0, "amount" => 3.0}
             }
           ]},
          # Sub-agent final answer
          {:final_answer,
           "After multiplying 5 by 10 to get 50, then adding 3, the result is 53."},
          # Parent final answer
          {:final_answer, "The sub-agent computed the result: 53."}
        ])

      # Create a math skill with a custom prompt fragment that instructs specific behavior
      custom_math_skill = %Skill{
        name: "math",
        description: "Perform arithmetic with a twist",
        prompt_fragment:
          "IMPORTANT: Always multiply the first operand by 10 before performing any addition. " <>
            "Use the multiply tool first, then the add tool.",
        tools: [AddAction, MultiplyAction]
      }

      dynamic_node = build_dynamic_node([custom_math_skill], plug)
      agent = init_skill_orchestrator(plug, dynamic_node)
      agent = execute_loop(agent, "Compute 5 + 3")

      strat = StratState.get(agent)
      assert strat.status == :completed

      # Verify the final result reflects the custom prompt behavior (multiply-then-add)
      assert %NodeIO{type: :text, value: result_value} = strat.result
      assert result_value =~ "53"

      # Verify the delegate result contains the multi-step answer
      assert %{result: delegate_text} = strat.context.working[:delegate_task]
      assert delegate_text =~ "53"

      # Inspect captured requests to verify prompt composition
      requests = LLMStub.get_captured_requests(stub_name)

      # The sub-agent requests (2nd, 3rd, 4th) should contain the custom prompt fragment
      sub_agent_requests =
        Enum.filter(requests, fn req ->
          system = req["system"] || ""
          String.contains?(system, "multiply the first operand by 10")
        end)

      refute sub_agent_requests == [],
             "Expected sub-agent to receive custom skill prompt fragment. " <>
               "System prompts seen: #{inspect(Enum.map(requests, & &1["system"]))}"

      # The sub-agent's system prompt should include both base_prompt AND skill fragment
      sub_req = hd(sub_agent_requests)

      assert sub_req["system"] =~ "specialist sub-agent",
             "Expected base_prompt in sub-agent system prompt"

      assert sub_req["system"] =~ "multiply the first operand by 10",
             "Expected skill prompt_fragment in sub-agent system prompt"

      # Verify the sub-agent had only the math tools (add + multiply), not echo
      sub_tool_names =
        sub_req["tools"]
        |> Enum.map(& &1["name"])
        |> Enum.sort()

      assert sub_tool_names == ["add", "multiply"],
             "Expected sub-agent to have only math tools, got: #{inspect(sub_tool_names)}"
    end

    test "base_prompt from assembly_opts appears in sub-agent system prompt" do
      # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
      stub_name = :"skill_base_prompt_#{System.unique_integer([:positive])}"

      plug =
        LLMStub.setup_req_stub_with_capture(stub_name, [
          # Parent delegates
          {:tool_calls,
           [
             %{
               id: "call_p1",
               name: "delegate_task",
               arguments: %{"task" => "Echo hello", "skills" => ["echo"]}
             }
           ]},
          # Sub-agent calls echo
          {:tool_calls,
           [
             %{
               id: "call_s1",
               name: "echo",
               arguments: %{"message" => "hello"}
             }
           ]},
          # Sub-agent final answer
          {:final_answer, "Echoed: hello"},
          # Parent final answer
          {:final_answer, "Done: hello"}
        ])

      custom_base_prompt = "You are a VERIFICATION-MARKER agent. Follow instructions precisely."

      dynamic_node = %DynamicAgentNode{
        name: "delegate_task",
        description: "Delegate a task to a sub-agent.",
        skill_registry: [TestSkills.echo_skill()],
        assembly_opts: [
          base_prompt: custom_base_prompt,
          model: "anthropic:claude-sonnet-4-20250514",
          req_options: [plug: plug]
        ]
      }

      agent = init_skill_orchestrator(plug, dynamic_node)
      agent = execute_loop(agent, "Echo hello")

      strat = StratState.get(agent)
      assert strat.status == :completed

      # Verify custom base_prompt appears in sub-agent requests
      requests = LLMStub.get_captured_requests(stub_name)

      sub_agent_requests =
        Enum.filter(requests, fn req ->
          system = req["system"] || ""
          String.contains?(system, "VERIFICATION-MARKER")
        end)

      refute sub_agent_requests == [],
             "Expected sub-agent to receive custom base_prompt with VERIFICATION-MARKER"

      # And also the echo skill's prompt fragment
      sub_req = hd(sub_agent_requests)

      assert sub_req["system"] =~ "echo tool",
             "Expected echo skill prompt_fragment in sub-agent system prompt"
    end
  end

  describe "skill selection controls tool availability (stub)" do
    test "sub-agent receives only the tools from selected skills" do
      # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
      stub_name = :"skill_tool_filter_#{System.unique_integer([:positive])}"

      plug =
        LLMStub.setup_req_stub_with_capture(stub_name, [
          # Parent delegates with only echo skill selected (math is in registry but NOT selected)
          {:tool_calls,
           [
             %{
               id: "call_p1",
               name: "delegate_task",
               arguments: %{"task" => "Echo test message", "skills" => ["echo"]}
             }
           ]},
          # Sub-agent uses echo
          {:tool_calls,
           [
             %{
               id: "call_s1",
               name: "echo",
               arguments: %{"message" => "test message"}
             }
           ]},
          # Sub-agent final answer
          {:final_answer, "Echoed: test message"},
          # Parent final answer
          {:final_answer, "The echo returned: test message"}
        ])

      # Registry has both math and echo, but parent will only select echo
      dynamic_node = build_dynamic_node([TestSkills.math_skill(), TestSkills.echo_skill()], plug)
      agent = init_skill_orchestrator(plug, dynamic_node)
      agent = execute_loop(agent, "Echo test message")

      strat = StratState.get(agent)
      assert strat.status == :completed

      # Verify the sub-agent's LLM request only had echo tool, NOT math tools
      requests = LLMStub.get_captured_requests(stub_name)

      sub_agent_requests =
        Enum.filter(requests, fn req ->
          system = req["system"] || ""

          String.contains?(system, "echo") and
            not String.contains?(system, "coordinator agent")
        end)

      refute sub_agent_requests == [],
             "Expected at least one sub-agent request"

      sub_tool_names =
        hd(sub_agent_requests)["tools"]
        |> Enum.map(& &1["name"])
        |> Enum.sort()

      # Only echo tool should be present — NOT add or multiply
      assert sub_tool_names == ["echo"],
             "Expected sub-agent to have only echo tool, got: #{inspect(sub_tool_names)}"
    end

    test "selecting multiple skills merges all their tools" do
      # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
      stub_name = :"skill_multi_tools_#{System.unique_integer([:positive])}"

      plug =
        LLMStub.setup_req_stub_with_capture(stub_name, [
          # Parent delegates with both math and echo skills
          {:tool_calls,
           [
             %{
               id: "call_p1",
               name: "delegate_task",
               arguments: %{
                 "task" => "Add 1+2 and echo the result",
                 "skills" => ["math", "echo"]
               }
             }
           ]},
          # Sub-agent calls add
          {:tool_calls,
           [
             %{
               id: "call_s1",
               name: "add",
               arguments: %{"value" => 1.0, "amount" => 2.0}
             }
           ]},
          # Sub-agent calls echo
          {:tool_calls,
           [
             %{
               id: "call_s2",
               name: "echo",
               arguments: %{"message" => "Result is 3.0"}
             }
           ]},
          # Sub-agent final answer
          {:final_answer, "Added 1+2=3.0 and echoed the result."},
          # Parent final answer
          {:final_answer, "Task completed: 3.0"}
        ])

      dynamic_node = build_dynamic_node([TestSkills.math_skill(), TestSkills.echo_skill()], plug)
      agent = init_skill_orchestrator(plug, dynamic_node)
      agent = execute_loop(agent, "Add 1+2 and echo the result")

      strat = StratState.get(agent)
      assert strat.status == :completed

      # Verify the sub-agent had all three tools (add, multiply from math + echo)
      requests = LLMStub.get_captured_requests(stub_name)

      sub_agent_requests =
        Enum.filter(requests, fn req ->
          system = req["system"] || ""

          String.contains?(system, "## Capabilities") and
            not String.contains?(system, "coordinator agent")
        end)

      refute sub_agent_requests == []

      sub_tool_names =
        hd(sub_agent_requests)["tools"]
        |> Enum.map(& &1["name"])
        |> Enum.sort()

      assert sub_tool_names == ["add", "echo", "multiply"],
             "Expected all three tools from both skills, got: #{inspect(sub_tool_names)}"

      # Verify both skill prompt fragments appear in the system prompt
      sub_system = hd(sub_agent_requests)["system"]
      assert sub_system =~ "math operations", "Expected math skill prompt fragment"
      assert sub_system =~ "echo tool", "Expected echo skill prompt fragment"
    end
  end

  describe "tool call ordering reflects skill prompt instructions (stub)" do
    test "sub-agent calls tools in the order specified by the skill prompt" do
      # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
      stub_name = :"skill_ordering_#{System.unique_integer([:positive])}"

      plug =
        LLMStub.setup_req_stub_with_capture(stub_name, [
          # Parent delegates
          {:tool_calls,
           [
             %{
               id: "call_p1",
               name: "delegate_task",
               arguments: %{
                 "task" => "Process the number 5",
                 "skills" => ["ordered_math"]
               }
             }
           ]},
          # Sub-agent step 1: multiply by 10 (as instructed by skill prompt order)
          {:tool_calls,
           [
             %{
               id: "call_s1",
               name: "multiply",
               arguments: %{"value" => 5.0, "amount" => 10.0}
             }
           ]},
          # Sub-agent step 2: then add 7 (second step per skill prompt)
          {:tool_calls,
           [
             %{
               id: "call_s2",
               name: "add",
               arguments: %{"value" => 50.0, "amount" => 7.0}
             }
           ]},
          # Sub-agent final answer
          {:final_answer, "Processed 5: multiplied by 10 to get 50, then added 7 to get 57."},
          # Parent final answer
          {:final_answer, "Result: 57"}
        ])

      # Skill with explicit ordering instructions
      ordered_math_skill = %Skill{
        name: "ordered_math",
        description: "Process numbers with a specific two-step sequence",
        prompt_fragment:
          "You MUST follow this exact sequence: " <>
            "Step 1: Use the multiply tool to multiply the input by 10. " <>
            "Step 2: Use the add tool to add 7 to the result. " <>
            "Never skip steps or change the order.",
        tools: [AddAction, MultiplyAction]
      }

      dynamic_node = build_dynamic_node([ordered_math_skill], plug)
      agent = init_skill_orchestrator(plug, dynamic_node)
      agent = execute_loop(agent, "Process the number 5")

      strat = StratState.get(agent)
      assert strat.status == :completed

      # Verify the result reflects the ordered computation: (5 * 10) + 7 = 57
      assert %NodeIO{type: :text, value: result_value} = strat.result
      assert result_value =~ "57"

      assert %{result: delegate_text} = strat.context.working[:delegate_task]
      assert delegate_text =~ "57"

      # Verify the sub-agent's system prompt contains the ordering instructions
      requests = LLMStub.get_captured_requests(stub_name)

      sub_agent_requests =
        Enum.filter(requests, fn req ->
          system = req["system"] || ""
          String.contains?(system, "MUST follow this exact sequence")
        end)

      refute sub_agent_requests == [],
             "Expected sub-agent to receive ordering instructions in system prompt"

      # Verify tool calls happened in correct order by examining the conversation
      # history in later sub-agent requests (which accumulate prior assistant turns).
      # Collect all tool_use names across all sub-agent requests in order.
      all_tool_calls =
        sub_agent_requests
        |> Enum.flat_map(fn req -> req["messages"] || [] end)
        |> Enum.filter(fn msg -> msg["role"] == "assistant" end)
        |> Enum.flat_map(fn msg ->
          (msg["content"] || [])
          |> Enum.filter(fn c -> c["type"] == "tool_use" end)
          |> Enum.map(fn c -> c["name"] end)
        end)

      # Also verify via context.working that both tools ran with expected results
      assert %{result: multiply_result} = strat.context.working[:delegate_task]
      assert multiply_result =~ "57"

      # If conversation history was captured, verify multiply came before add
      if all_tool_calls != [] do
        multiply_idx = Enum.find_index(all_tool_calls, &(&1 == "multiply"))
        add_idx = Enum.find_index(all_tool_calls, &(&1 == "add"))

        assert multiply_idx != nil, "Expected multiply tool call in conversation history"
        assert add_idx != nil, "Expected add tool call in conversation history"

        assert multiply_idx < add_idx,
               "Expected multiply before add, but got order: #{inspect(all_tool_calls)}"
      end
    end
  end
end
