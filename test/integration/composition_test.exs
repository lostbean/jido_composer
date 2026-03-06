defmodule Jido.Composer.Integration.CompositionTest do
  use ExUnit.Case, async: true

  alias Jido.Agent.Directive
  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.Composer.TestSupport.LLMStub

  alias Jido.Composer.TestActions.{ExtractAction, TransformAction, LoadAction}

  # -- Workflow definition (to be used as a tool) --

  defmodule ETLWorkflow do
    use Jido.Composer.Workflow,
      name: "etl_workflow",
      description: "Extract, transform, and load data from a source",
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

  # -- Orchestrator that can invoke workflow as a tool --

  defmodule WorkflowOrchestrator do
    use Jido.Composer.Orchestrator,
      name: "workflow_orchestrator",
      description: "Orchestrator that can invoke workflows as tools",
      nodes: [
        Jido.Composer.TestActions.EchoAction,
        Jido.Composer.Integration.CompositionTest.ETLWorkflow
      ],
      system_prompt: "You can run ETL workflows and echo messages."
  end

  # -- Orchestrator with only action tools --

  defmodule SimpleOrchestrator do
    use Jido.Composer.Orchestrator,
      name: "simple_orchestrator",
      nodes: [
        Jido.Composer.TestActions.AddAction,
        Jido.Composer.TestActions.EchoAction
      ],
      system_prompt: "You have math and echo tools."
  end

  # -- Helpers --

  defp execute_orchestrator(agent_module, agent, directives) do
    run_directive_loop(agent_module, agent, directives)
  end

  defp run_directive_loop(_agent_module, agent, []), do: agent

  defp run_directive_loop(agent_module, agent, [directive | rest]) do
    case directive do
      %Directive.RunInstruction{instruction: instr, result_action: result_action, meta: meta} ->
        payload = execute_instruction(instr, meta)
        {agent, new_directives} = agent_module.cmd(agent, {result_action, payload})
        run_directive_loop(agent_module, agent, new_directives ++ rest)

      %Directive.SpawnAgent{agent: child_module, tag: tag, opts: spawn_opts} ->
        # Simulate workflow execution as a tool call
        result = simulate_workflow_tool(child_module, spawn_opts)

        {agent, new_directives} =
          agent_module.cmd(
            agent,
            {:orchestrator_child_result, %{tag: tag, result: result}}
          )

        run_directive_loop(agent_module, agent, new_directives ++ rest)

      _other ->
        run_directive_loop(agent_module, agent, rest)
    end
  end

  defp simulate_workflow_tool(child_module, spawn_opts) do
    context = Map.get(spawn_opts, :context, %{})

    # Create and run the workflow agent
    agent = child_module.new()
    {agent, directives} = child_module.run(agent, context)

    # Execute the workflow's directive loop
    agent = run_workflow_directives(child_module, agent, directives)

    # Extract result from the workflow
    strat = StratState.get(agent)

    if strat.machine.status == :done do
      {:ok, strat.machine.context}
    else
      {:error, "workflow failed"}
    end
  end

  defp run_workflow_directives(_module, agent, []), do: agent

  defp run_workflow_directives(module, agent, [directive | rest]) do
    case directive do
      %Directive.RunInstruction{instruction: instr, result_action: result_action} ->
        payload = execute_action_instruction(instr)
        {agent, new_directives} = module.cmd(agent, {result_action, payload})
        run_workflow_directives(module, agent, new_directives ++ rest)

      _other ->
        run_workflow_directives(module, agent, rest)
    end
  end

  defp execute_action_instruction(%Jido.Instruction{action: action_module, params: params}) do
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

  defp execute_instruction(
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

  defp execute_instruction(%Jido.Instruction{action: action_module, params: params}, meta) do
    case Jido.Exec.run(action_module, params) do
      {:ok, result} ->
        %{status: :ok, result: result, meta: meta || %{}}

      {:error, reason} ->
        %{status: :error, result: reason, meta: meta || %{}}
    end
  end

  # -- Tests --

  describe "orchestrator invokes workflow-as-tool" do
    test "workflow agent appears as a tool to the orchestrator" do
      agent = WorkflowOrchestrator.new()
      strat = StratState.get(agent)

      tool_names = Enum.map(strat.tools, & &1.name)
      assert "echo" in tool_names
      assert "etl_workflow" in tool_names
    end

    test "orchestrator invokes workflow tool and gets result" do
      LLMStub.setup([
        {:tool_calls,
         [
           %{
             id: "call_1",
             name: "etl_workflow",
             arguments: %{"source" => "test_db"}
           }
         ]},
        {:final_answer, "ETL complete. Loaded 2 records from test_db."}
      ])

      agent = WorkflowOrchestrator.new()
      {agent, directives} = WorkflowOrchestrator.query(agent, "Run ETL on test_db")
      agent = execute_orchestrator(WorkflowOrchestrator, agent, directives)

      strat = StratState.get(agent)
      assert strat.status == :completed
      assert strat.result.value =~ "ETL complete"

      # Workflow result should be scoped in context
      assert strat.context[:etl_workflow] != nil
    end

    test "orchestrator mixes action tools and workflow tools" do
      LLMStub.setup([
        {:tool_calls,
         [
           %{id: "call_1", name: "echo", arguments: %{"message" => "starting ETL"}}
         ]},
        {:tool_calls,
         [
           %{
             id: "call_2",
             name: "etl_workflow",
             arguments: %{"source" => "test_db"}
           }
         ]},
        {:final_answer, "Done. Echoed a message and ran the ETL pipeline."}
      ])

      agent = WorkflowOrchestrator.new()
      {agent, directives} = WorkflowOrchestrator.query(agent, "Echo then ETL")
      agent = execute_orchestrator(WorkflowOrchestrator, agent, directives)

      strat = StratState.get(agent)
      assert strat.status == :completed
      assert strat.context[:echo][:echoed] == "starting ETL"
      assert strat.context[:etl_workflow] != nil
    end
  end

  describe "AgentNode in FanOut" do
    test "FanOut branch with AgentNode executes successfully" do
      alias Jido.Composer.Node.{ActionNode, FanOutNode}
      alias Jido.Composer.TestAgents.TestWorkflowAgent

      {:ok, action_node} = ActionNode.new(Jido.Composer.TestActions.EchoAction)
      {:ok, agent_node} = Jido.Composer.Node.AgentNode.new(TestWorkflowAgent)

      {:ok, fan_out} =
        FanOutNode.new(
          name: "mixed_fanout",
          branches: [
            echo_branch: action_node,
            workflow_branch: agent_node
          ]
        )

      context = %{
        message: "hello",
        source: "test_db",
        extract: %{records: [%{id: 1, source: "test"}], count: 1}
      }

      assert {:ok, result} = FanOutNode.run(fan_out, context)
      assert Map.has_key?(result, :echo_branch)
      assert Map.has_key?(result, :workflow_branch)
    end
  end

  describe "three-level nesting (orchestrator -> workflow -> action)" do
    test "full three-level nesting with workflow results flowing back" do
      LLMStub.setup([
        {:tool_calls,
         [
           %{
             id: "call_1",
             name: "etl_workflow",
             arguments: %{"source" => "production_db"}
           }
         ]},
        {:final_answer, "Processed data from production_db via ETL workflow."}
      ])

      agent = WorkflowOrchestrator.new()
      {agent, directives} = WorkflowOrchestrator.query(agent, "Process production data")
      agent = execute_orchestrator(WorkflowOrchestrator, agent, directives)

      strat = StratState.get(agent)
      assert strat.status == :completed

      # Verify full context flow: orchestrator -> workflow -> actions
      etl_ctx = strat.context[:etl_workflow]
      assert etl_ctx != nil

      # The workflow ran extract -> transform -> load internally
      assert etl_ctx[:extract][:records] != nil
      assert etl_ctx[:transform][:records] != nil
      assert etl_ctx[:load][:status] == :complete
    end
  end
end
