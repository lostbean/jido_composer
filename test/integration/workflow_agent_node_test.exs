defmodule Jido.Composer.Integration.WorkflowAgentNodeTest do
  use ExUnit.Case, async: true

  alias Jido.Agent.Directive
  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.Composer.Node.AgentNode
  alias Jido.Composer.TestAgents.EchoAgent

  alias Jido.Composer.TestActions.{ExtractAction, LoadAction, EchoAction}

  # -- Workflow with AgentNode --

  # A workflow where one step is an agent node rather than an action node.
  # The DSL detects {module, opts} tuples as agent nodes.
  defmodule AgentStepWorkflow do
    use Jido.Composer.Workflow,
      name: "agent_step_workflow",
      description: "Workflow with one AgentNode step",
      nodes: %{
        extract: ExtractAction,
        process: {EchoAgent, []},
        load: LoadAction
      },
      transitions: %{
        {:extract, :ok} => :process,
        {:process, :ok} => :load,
        {:load, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :extract
  end

  # Workflow where the agent node is the first step
  defmodule AgentFirstWorkflow do
    use Jido.Composer.Workflow,
      name: "agent_first_workflow",
      nodes: %{
        agent_step: {EchoAgent, []},
        finish: EchoAction
      },
      transitions: %{
        {:agent_step, :ok} => :finish,
        {:finish, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :agent_step
  end

  # -- Helpers --

  # Simulates the AgentServer directive execution loop.
  # Handles both RunInstruction (for ActionNode) and SpawnAgent (for AgentNode) directives.
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

      %Directive.SpawnAgent{agent: child_agent_module, tag: tag, opts: spawn_opts} ->
        # Simulate the SpawnAgent lifecycle:
        # 1. Child is spawned -> child_started signal
        # 2. Strategy sends context to child
        # 3. Child processes and returns result -> child_result signal

        # Step 1: Notify strategy that child started
        {agent, child_started_directives} =
          agent_module.cmd(agent, {:workflow_child_started, %{tag: tag, child_pid: self()}})

        # Step 2: Process any directives from child_started (e.g., Emit to send context)
        # For the simulation, we extract the context that was sent and simulate child processing
        {agent, context_to_send, remaining_directives} =
          process_child_started_directives(agent_module, agent, child_started_directives)

        # Step 3: Simulate child agent running and producing a result
        child_result = simulate_child_agent(child_agent_module, context_to_send, spawn_opts)

        # Step 4: Feed child result back to strategy
        {agent, result_directives} =
          agent_module.cmd(agent, {:workflow_child_result, %{tag: tag, result: child_result}})

        run_directive_loop(agent_module, agent, remaining_directives ++ result_directives ++ rest)

      _other ->
        run_directive_loop(agent_module, agent, rest)
    end
  end

  defp process_child_started_directives(_agent_module, agent, directives) do
    # Look for Emit directives that carry context to the child
    {emit_directives, other_directives} =
      Enum.split_with(directives, fn
        %Directive.Emit{} -> true
        _ -> false
      end)

    # Extract context from emit directive if present
    context_to_send =
      case emit_directives do
        [%Directive.Emit{signal: signal} | _] ->
          if is_struct(signal) do
            Map.get(signal, :data, %{})
          else
            %{}
          end

        _ ->
          %{}
      end

    {agent, context_to_send, other_directives}
  end

  defp simulate_child_agent(_child_module, context, _opts) do
    # Simulate a simple agent that echoes its input context
    # In a real scenario, the child agent would run its own strategy
    {:ok, context}
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
          reason: reason,
          instruction: %Jido.Instruction{action: action_module, params: params},
          effects: [],
          meta: %{}
        }
    end
  end

  # -- DSL run_sync tests --

  describe "AgentNode via run_sync" do
    test "workflow with nested workflow agent completes via run_sync" do
      defmodule NestedWorkflowViaSyncWorkflow do
        use Jido.Composer.Workflow,
          name: "nested_sync_workflow",
          nodes: %{
            extract: Jido.Composer.TestActions.ExtractAction,
            nested: {Jido.Composer.TestAgents.TestWorkflowAgent, []}
          },
          transitions: %{
            {:extract, :ok} => :nested,
            {:nested, :ok} => :done,
            {:_, :error} => :failed
          },
          initial: :extract
      end

      agent = NestedWorkflowViaSyncWorkflow.new()
      assert {:ok, result} = NestedWorkflowViaSyncWorkflow.run_sync(agent, %{source: "test_db"})
      assert Map.has_key?(result, :nested)
      assert result[:nested][:load][:status] == :complete
    end
  end

  # -- Tests --

  describe "AgentNode in workflow" do
    test "strategy builds AgentNode for {module, opts} node specs" do
      agent = AgentStepWorkflow.new()
      strat = StratState.get(agent)

      process_node = strat.machine.nodes[:process]
      assert %AgentNode{} = process_node
      assert process_node.agent_module == EchoAgent
    end

    test "dispatches SpawnAgent directive for AgentNode steps" do
      agent = AgentStepWorkflow.new()
      {agent, directives} = AgentStepWorkflow.run(agent, %{source: "test_db"})

      # First directive should be RunInstruction for extract (ActionNode)
      assert [%Directive.RunInstruction{}] = directives

      # Execute extract step
      payload = execute_instruction(hd(directives).instruction)
      {_agent, directives2} = AgentStepWorkflow.cmd(agent, {:workflow_node_result, payload})

      # After extract succeeds, next step is process (AgentNode)
      # Should emit a SpawnAgent directive
      assert [%Directive.SpawnAgent{agent: EchoAgent}] = directives2
    end

    test "completes workflow with mixed ActionNode and AgentNode steps" do
      agent = AgentStepWorkflow.new()
      {agent, directives} = AgentStepWorkflow.run(agent, %{source: "test_db"})

      agent = execute_workflow(AgentStepWorkflow, agent, directives)

      strat = StratState.get(agent)
      assert strat.machine.status == :done
      assert StratState.status(agent) == :success
    end

    test "context flows across agent boundary" do
      agent = AgentStepWorkflow.new()
      {agent, directives} = AgentStepWorkflow.run(agent, %{source: "test_db"})

      agent = execute_workflow(AgentStepWorkflow, agent, directives)

      strat = StratState.get(agent)
      ctx = strat.machine.context

      # Extract step should have produced its result
      assert ctx[:extract][:records] != nil
      # Process (agent) step result should be scoped
      assert Map.has_key?(ctx, :process)
      # Load step should have completed
      assert ctx[:load][:status] == :complete
    end

    test "agent node as first step emits SpawnAgent directive" do
      agent = AgentFirstWorkflow.new()
      {_agent, directives} = AgentFirstWorkflow.run(agent, %{message: "hello"})

      # First step is an AgentNode, should emit SpawnAgent
      assert [%Directive.SpawnAgent{agent: EchoAgent}] = directives
    end

    test "child result failure transitions to error state" do
      agent = AgentStepWorkflow.new()
      {agent, directives} = AgentStepWorkflow.run(agent, %{source: "test_db"})

      # Execute extract step normally
      payload = execute_instruction(hd(directives).instruction)
      {agent, directives2} = AgentStepWorkflow.cmd(agent, {:workflow_node_result, payload})

      # SpawnAgent for process step
      assert [%Directive.SpawnAgent{}] = directives2

      # Simulate child_started
      {agent, _} =
        AgentStepWorkflow.cmd(agent, {:workflow_child_started, %{tag: nil, child_pid: self()}})

      # Simulate child failure
      {agent, _} =
        AgentStepWorkflow.cmd(
          agent,
          {:workflow_child_result, %{tag: nil, result: {:error, "child failed"}}}
        )

      strat = StratState.get(agent)
      assert strat.machine.status == :failed
      assert StratState.status(agent) == :failure
    end
  end
end
