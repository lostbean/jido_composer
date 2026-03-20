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

  alias Jido.Composer.TestActions.{AddAction, MultiplyAction, EchoAction}
  alias Jido.Composer.TestAgents.TestWorkflowAgent

  # ── Bare agent for strategy-level cassette tests ──

  defmodule SkillCassetteAgent do
    @moduledoc false
    use Jido.Agent,
      name: "skill_cassette_agent",
      description: "Agent for skill assembly cassette tests",
      schema: []
  end

  # ── Skill definitions ──

  defp math_skill do
    %Skill{
      name: "math",
      description: "Perform arithmetic operations like addition and multiplication",
      prompt_fragment: "You can perform math operations using the add and multiply tools.",
      tools: [AddAction, MultiplyAction]
    }
  end

  defp echo_skill do
    %Skill{
      name: "echo",
      description: "Echo messages back to the user",
      prompt_fragment: "You can echo messages using the echo tool.",
      tools: [EchoAction]
    }
  end

  defp pipeline_skill do
    %Skill{
      name: "pipeline",
      description: "Run data transformation pipelines",
      prompt_fragment: "You can run data pipelines using the test_workflow_agent tool.",
      tools: [TestWorkflowAgent]
    }
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
      with_cassette(
        "e2e_skill_assembly_math",
        CassetteHelper.default_cassette_opts(),
        fn plug ->
          dynamic_node = build_dynamic_node([math_skill(), echo_skill()], plug)
          agent = init_skill_orchestrator(plug, dynamic_node)

          agent =
            execute_loop(
              agent,
              "What is 5 + 3? Use the delegate_task tool with the math skill to compute this."
            )

          strat = StratState.get(agent)
          assert strat.status == :completed
          assert strat.result != nil
        end
      )
    end
  end

  # ══════════════════════════════════════════════════════════════════
  # E2E: Skill assembly with mixed node types (cassette)
  # ══════════════════════════════════════════════════════════════════

  describe "skill assembly: mixed action + workflow-agent skills (cassette)" do
    test "sub-agent assembles with both action and workflow-agent tools" do
      with_cassette(
        "e2e_skill_assembly_mixed",
        CassetteHelper.default_cassette_opts(),
        fn plug ->
          dynamic_node =
            build_dynamic_node([math_skill(), pipeline_skill()], plug)

          agent = init_skill_orchestrator(plug, dynamic_node)

          agent =
            execute_loop(
              agent,
              "Use the delegate_task tool with the math skill. Ask it to add 10 and 20."
            )

          strat = StratState.get(agent)
          assert strat.status == :completed
          assert strat.result != nil
        end
      )
    end
  end
end
