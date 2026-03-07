defmodule Jido.Composer.Integration.PersistenceCascadeTest do
  @moduledoc """
  Integration tests for the persistence cascade implementation.

  Validates the full checkpoint/thaw/resume lifecycle across:
  - Orchestrator child_phases tracking
  - Orchestrator checkpoint/thaw/resume full cycle
  - Nested workflow→orchestrator checkpoint/resume
  - Replay directives for orchestrator in-flight operations
  - ChildRef phase field persistence
  - CheckpointAndStop directive emission
  - Suspend directive hibernate field serialization
  """
  use ExUnit.Case, async: true

  alias Jido.Agent.Directive
  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.AgentServer.DirectiveExec
  alias Jido.AgentServer.ParentRef
  alias Jido.Composer.Checkpoint
  alias Jido.Composer.ChildRef
  alias Jido.Composer.Context
  alias Jido.Composer.Directive.CheckpointAndStop
  alias Jido.Composer.Directive.Suspend, as: SuspendDirective
  alias Jido.Composer.HITL.ApprovalResponse
  alias Jido.Composer.Node.AgentNode
  alias Jido.Composer.Node.HumanNode
  alias Jido.Composer.Orchestrator.Strategy, as: OrchStrategy
  alias Jido.Composer.Suspension
  alias Jido.Composer.TestSupport.LLMStub

  alias Jido.Composer.TestActions.{
    AccumulatorAction,
    EchoAction,
    NoopAction
  }

  # ── Test Agents ──────────────────────────────────────────────

  defmodule OrchestratorAgent do
    @moduledoc false
    use Jido.Agent,
      name: "persistence_orchestrator",
      description: "Bare agent for orchestrator strategy tests",
      schema: []
  end

  defmodule InnerOrchestrator do
    @moduledoc false
    use Jido.Composer.Orchestrator,
      name: "inner_orchestrator",
      description: "Child orchestrator for nesting tests",
      nodes: [EchoAction],
      system_prompt: "Echo tool available."
  end

  defmodule OuterWorkflowWithOrchestrator do
    @moduledoc false
    use Jido.Composer.Workflow,
      name: "outer_workflow_orch",
      description: "Workflow that nests an orchestrator as a child agent",
      nodes: %{
        prepare: AccumulatorAction,
        analyze: {InnerOrchestrator, []},
        finish: NoopAction
      },
      transitions: %{
        {:prepare, :ok} => :analyze,
        {:analyze, :ok} => :finish,
        {:finish, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :prepare
  end

  defmodule WorkflowWithHumanAndOrchestrator do
    @moduledoc false
    use Jido.Composer.Workflow,
      name: "workflow_human_orch",
      description: "Workflow with HumanNode then orchestrator child",
      nodes: %{
        gather: AccumulatorAction,
        approval: %HumanNode{
          name: "approval",
          description: "Approve",
          prompt: "Approve analysis?",
          allowed_responses: [:approved, :rejected],
          timeout: 30_000
        },
        analyze: {InnerOrchestrator, []},
        finish: NoopAction
      },
      transitions: %{
        {:gather, :ok} => :approval,
        {:approval, :approved} => :analyze,
        {:approval, :rejected} => :failed,
        {:approval, :timeout} => :failed,
        {:analyze, :ok} => :finish,
        {:finish, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :gather
  end

  # ── Helpers ──────────────────────────────────────────────────

  defp init_orchestrator_agent(opts \\ []) do
    nodes = Keyword.get(opts, :nodes, [EchoAction])
    gated_nodes = Keyword.get(opts, :gated_nodes, [])

    strategy_opts =
      [
        nodes: nodes,
        model: "stub:test-model",
        system_prompt: "You are a helpful assistant.",
        max_iterations: 10,
        gated_nodes: gated_nodes
      ] ++ Keyword.take(opts, [:hibernate_after])

    agent = OrchestratorAgent.new()
    ctx = %{strategy_opts: strategy_opts}
    {agent, _directives} = OrchStrategy.init(agent, ctx)
    agent
  end

  defp make_instruction(action, params) do
    %Jido.Instruction{action: action, params: params}
  end

  defp execute_until_suspend(_mod, agent, []), do: {agent, []}

  defp execute_until_suspend(mod, agent, [directive | rest]) do
    case directive do
      %Directive.RunInstruction{instruction: instr, result_action: result_action, meta: meta} ->
        payload = execute_instruction(instr, meta)
        {agent, new_directives} = mod.cmd(agent, {result_action, payload})
        execute_until_suspend(mod, agent, new_directives ++ rest)

      %Directive.SpawnAgent{agent: child_module, tag: tag, opts: spawn_opts} ->
        {agent, _} = mod.cmd(agent, {:workflow_child_started, %{tag: tag, child_pid: self()}})
        child_result = simulate_child_sync(child_module, spawn_opts)

        {agent, new_directives} =
          mod.cmd(agent, {:workflow_child_result, %{tag: tag, result: child_result}})

        execute_until_suspend(mod, agent, new_directives ++ rest)

      %SuspendDirective{} = suspend ->
        {agent, [suspend | rest]}

      _other ->
        execute_until_suspend(mod, agent, rest)
    end
  end

  defp execute_orchestrator_directives(agent, []), do: {agent, []}

  defp execute_orchestrator_directives(agent, [directive | rest]) do
    case directive do
      %Directive.RunInstruction{
        instruction: %Jido.Instruction{action: Jido.Composer.Orchestrator.LLMAction} = instr,
        result_action: result_action
      } ->
        payload = execute_llm(instr)

        {agent, new_directives} =
          OrchStrategy.cmd(agent, [make_instruction(result_action, payload)], %{})

        execute_orchestrator_directives(agent, new_directives ++ rest)

      %Directive.RunInstruction{
        instruction: %Jido.Instruction{action: action_module, params: params},
        result_action: result_action,
        meta: meta
      } ->
        payload = execute_action(action_module, params, meta)

        {agent, new_directives} =
          OrchStrategy.cmd(agent, [make_instruction(result_action, payload)], %{})

        execute_orchestrator_directives(agent, new_directives ++ rest)

      %SuspendDirective{} = suspend ->
        {agent, [suspend | rest]}

      _other ->
        execute_orchestrator_directives(agent, rest)
    end
  end

  defp execute_llm(%Jido.Instruction{params: params}) do
    case LLMStub.execute(params) do
      {:ok, %{response: response, conversation: conversation}} ->
        %{status: :ok, result: %{response: response, conversation: conversation}, meta: %{}}

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

  defp execute_instruction(
         %Jido.Instruction{action: Jido.Composer.Orchestrator.LLMAction} = instr,
         _meta
       ) do
    execute_llm(instr)
  end

  defp execute_instruction(%Jido.Instruction{action: action_module, params: params}, meta) do
    execute_action(action_module, params, meta)
  end

  defp simulate_child_sync(child_module, spawn_opts) do
    context = Map.get(spawn_opts, :context, %{})
    Jido.Composer.Node.execute_child_sync(child_module, %{context: context})
  end

  defp checkpoint_and_thaw(strat) do
    checkpoint = Checkpoint.prepare_for_checkpoint(strat)
    binary = :erlang.term_to_binary(checkpoint, [:compressed])
    :erlang.binary_to_term(binary)
  end

  # ══════════════════════════════════════════════════════════════
  # Orchestrator child_phases tracking
  # ══════════════════════════════════════════════════════════════

  describe "orchestrator child_phases tracking" do
    test "both workflow and orchestrator strategies initialize child_phases" do
      wf_agent = OuterWorkflowWithOrchestrator.new()
      wf_strat = StratState.get(wf_agent)
      assert Map.has_key?(wf_strat, :child_phases)
      assert wf_strat.child_phases == %{}

      orch_agent = init_orchestrator_agent()
      orch_strat = StratState.get(orch_agent)
      assert Map.has_key?(orch_strat, :child_phases)
      assert orch_strat.child_phases == %{}
    end

    test "orchestrator child_started sets phase to :awaiting_result" do
      agent = init_orchestrator_agent()

      tool_call = %{id: "call_1", name: "echo", arguments: %{"message" => "hello"}}
      LLMStub.setup([{:tool_calls, [tool_call]}])

      {agent, _directives} =
        OrchStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_start, %{query: "Echo hello"})],
          %{}
        )

      {agent, _} =
        OrchStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_child_started, %{tag: :test_child, child_pid: self()})],
          %{}
        )

      strat = StratState.get(agent)
      assert strat.child_phases[:test_child] == :awaiting_result
    end

    test "orchestrator child_result clears phase" do
      agent = init_orchestrator_agent()

      tool_call = %{id: "call_1", name: "echo", arguments: %{"message" => "hello"}}
      LLMStub.setup([{:tool_calls, [tool_call]}, {:final_answer, "Done"}])

      {agent, _directives} =
        OrchStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_start, %{query: "Echo hello"})],
          %{}
        )

      tag = {:tool_call, "call_1", "echo"}

      {agent, _} =
        OrchStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_child_started, %{tag: tag, child_pid: self()})],
          %{}
        )

      strat = StratState.get(agent)
      assert strat.child_phases[tag] == :awaiting_result

      {agent, _} =
        OrchStrategy.cmd(
          agent,
          [
            make_instruction(:orchestrator_child_result, %{
              tag: tag,
              result: {:ok, %{echoed: "hello"}}
            })
          ],
          %{}
        )

      strat = StratState.get(agent)
      refute Map.has_key?(strat.child_phases, tag)
    end

    test "child_phases survives checkpoint/thaw" do
      agent = init_orchestrator_agent()

      tool_call = %{id: "call_1", name: "echo", arguments: %{"message" => "hello"}}
      LLMStub.setup([{:tool_calls, [tool_call]}])

      {agent, _directives} =
        OrchStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_start, %{query: "Echo hello"})],
          %{}
        )

      tag = {:tool_call, "call_1", "echo"}

      {agent, _} =
        OrchStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_child_started, %{tag: tag, child_pid: self()})],
          %{}
        )

      strat = StratState.get(agent)
      assert strat.child_phases[tag] == :awaiting_result

      restored = checkpoint_and_thaw(strat)
      assert restored.child_phases[tag] == :awaiting_result
    end
  end

  # ══════════════════════════════════════════════════════════════
  # Orchestrator full checkpoint/thaw/resume cycle
  # ══════════════════════════════════════════════════════════════

  describe "orchestrator checkpoint/thaw/resume" do
    test "gated tool suspends, checkpoints, thaws, and resumes to completion" do
      agent = init_orchestrator_agent(gated_nodes: ["echo"])

      tool_call = %{id: "call_1", name: "echo", arguments: %{"message" => "checkpoint test"}}

      LLMStub.setup([
        {:tool_calls, [tool_call]},
        {:final_answer, "Echo result received"}
      ])

      # Run until suspension (gated tool)
      {agent, directives} =
        OrchStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_start, %{query: "Echo this"})],
          %{}
        )

      {agent, remaining} = execute_orchestrator_directives(agent, directives)

      strat = StratState.get(agent)
      assert strat.status == :awaiting_approval
      assert [%SuspendDirective{} | _] = remaining

      # Checkpoint
      checkpoint_data = Checkpoint.prepare_for_checkpoint(strat)
      binary = :erlang.term_to_binary(checkpoint_data, [:compressed])
      assert byte_size(binary) > 0

      # Simulate process death + thaw
      fresh_agent = OrchestratorAgent.new()
      restored_strat = :erlang.binary_to_term(binary)
      restored_strat = Checkpoint.reattach_runtime_config(restored_strat, [])
      restored_agent = StratState.put(fresh_agent, restored_strat)

      # Verify restored state
      restored = StratState.get(restored_agent)
      assert restored.status == :awaiting_approval
      assert map_size(restored.gated_calls) == 1

      # Resume with approval
      [{request_id, _}] = Map.to_list(restored.gated_calls)
      {:ok, response} = ApprovalResponse.new(request_id: request_id, decision: :approved)

      LLMStub.setup([{:final_answer, "Echo result received"}])

      {resumed_agent, directives} =
        OrchStrategy.cmd(
          restored_agent,
          [make_instruction(:hitl_response, Map.from_struct(response))],
          %{}
        )

      # Execute to completion
      {final_agent, _} = execute_orchestrator_directives(resumed_agent, directives)

      final_strat = StratState.get(final_agent)
      assert final_strat.status == :completed
      assert final_strat.result.value == "Echo result received"
    end

    test "suspended state survives checkpoint/thaw" do
      agent = init_orchestrator_agent(gated_nodes: ["echo"])

      tool_call = %{id: "call_1", name: "echo", arguments: %{"message" => "test"}}
      LLMStub.setup([{:tool_calls, [tool_call]}])

      {agent, directives} =
        OrchStrategy.cmd(agent, [make_instruction(:orchestrator_start, %{query: "Echo"})], %{})

      {agent, _remaining} = execute_orchestrator_directives(agent, directives)

      strat = StratState.get(agent)
      assert strat.status == :awaiting_approval

      checkpoint_data = Checkpoint.prepare_for_checkpoint(strat)
      binary = :erlang.term_to_binary(checkpoint_data, [:compressed])

      fresh_agent = OrchestratorAgent.new()
      restored_strat = :erlang.binary_to_term(binary)
      restored_agent = StratState.put(fresh_agent, restored_strat)
      restored = StratState.get(restored_agent)

      assert restored.status == :awaiting_approval
      assert map_size(restored.gated_calls) > 0
      assert restored.conversation != nil
    end
  end

  # ══════════════════════════════════════════════════════════════
  # Nested workflow→orchestrator checkpoint/resume
  # ══════════════════════════════════════════════════════════════

  describe "nested workflow→orchestrator checkpoint/resume" do
    test "parent workflow checkpoints at HumanNode, thaws, resumes through orchestrator child" do
      agent = WorkflowWithHumanAndOrchestrator.new()
      {agent, directives} = WorkflowWithHumanAndOrchestrator.run(agent, %{tag: "nested-test"})

      {agent, _remaining} =
        execute_until_suspend(WorkflowWithHumanAndOrchestrator, agent, directives)

      strat = StratState.get(agent)
      assert strat.status == :waiting
      assert strat.pending_suspension != nil
      assert strat.machine.status == :approval

      # Checkpoint + thaw
      checkpoint_data = Checkpoint.prepare_for_checkpoint(strat)
      binary = :erlang.term_to_binary(checkpoint_data, [:compressed])

      fresh_agent = WorkflowWithHumanAndOrchestrator.new()
      restored_strat = :erlang.binary_to_term(binary)
      restored_agent = StratState.put(fresh_agent, restored_strat)

      # Resume with approval → transitions to :analyze (orchestrator child)
      restored = StratState.get(restored_agent)

      {:ok, response} =
        ApprovalResponse.new(
          request_id: restored.pending_suspension.approval_request.id,
          decision: :approved
        )

      {resumed_agent, directives} =
        WorkflowWithHumanAndOrchestrator.cmd(
          restored_agent,
          {:hitl_response, Map.from_struct(response)}
        )

      case directives do
        [%Directive.RunInstruction{} | _] ->
          {final_agent, _} =
            execute_until_suspend(WorkflowWithHumanAndOrchestrator, resumed_agent, directives)

          final_strat = StratState.get(final_agent)
          assert final_strat.machine.status == :done

        directives when is_list(directives) ->
          # SpawnAgent for orchestrator child — verify parent transitioned correctly
          resumed_strat = StratState.get(resumed_agent)
          assert resumed_strat.status == :running
          assert resumed_strat.machine.status == :analyze
      end
    end

    test "ChildRef tracks orchestrator child across checkpoint boundary" do
      child_ref =
        ChildRef.new(
          agent_module: InnerOrchestrator,
          agent_id: "orch-child-001",
          tag: {:tool_call, "tc-1", "inner_orchestrator"},
          status: :running
        )

      parent_strat = %{
        module: Jido.Composer.Workflow.Strategy,
        status: :running,
        machine: %{status: :analyze, context: %{gather: %{tag: "test"}}},
        pending_suspension: nil,
        pending_fan_out: nil,
        children: %{{:tool_call, "tc-1", "inner_orchestrator"} => child_ref},
        child_phases: %{{:tool_call, "tc-1", "inner_orchestrator"} => :awaiting_result}
      }

      restored = checkpoint_and_thaw(parent_strat)

      tag = {:tool_call, "tc-1", "inner_orchestrator"}
      assert Map.has_key?(restored.children, tag)
      assert restored.children[tag].agent_module == InnerOrchestrator
      assert restored.children[tag].status == :running
      assert restored.child_phases[tag] == :awaiting_result
      assert Map.has_key?(child_ref, :phase)
    end
  end

  # ══════════════════════════════════════════════════════════════
  # Replay directives for orchestrator in-flight operations
  # ══════════════════════════════════════════════════════════════

  describe "replay_directives for orchestrator" do
    test "replays LLM call for orchestrator in awaiting_llm state" do
      workflow_state = %{
        module: Jido.Composer.Workflow.Strategy,
        children: %{
          worker:
            ChildRef.new(
              agent_module: InnerOrchestrator,
              agent_id: "w-child-1",
              tag: :worker
            )
        },
        child_phases: %{worker: :spawning}
      }

      wf_replays = Checkpoint.replay_directives(workflow_state)
      assert length(wf_replays) == 1
      assert [%Directive.SpawnAgent{agent: InnerOrchestrator, tag: :worker}] = wf_replays

      orch_state = %{
        module: Jido.Composer.Orchestrator.Strategy,
        status: :awaiting_llm,
        conversation: [%{role: "user", content: "test"}],
        pending_tool_calls: [],
        completed_tool_results: [],
        children: %{},
        model: "stub:test-model",
        query: "test query",
        system_prompt: "You are a helpful assistant.",
        tools: [],
        temperature: nil,
        max_tokens: nil,
        stream: false,
        output_schema: nil,
        llm_opts: [],
        req_options: []
      }

      orch_replays = Checkpoint.replay_directives(orch_state)

      assert length(orch_replays) == 1
      assert [%Directive.RunInstruction{result_action: :orchestrator_llm_result}] = orch_replays

      [%Directive.RunInstruction{instruction: instr}] = orch_replays
      assert instr.action == Jido.Composer.Orchestrator.LLMAction
      assert instr.params.conversation == [%{role: "user", content: "test"}]
      assert instr.params.model == "stub:test-model"
    end

    test "re-dispatches pending tool calls after checkpoint/thaw" do
      orch_state = %{
        module: Jido.Composer.Orchestrator.Strategy,
        status: :awaiting_tool,
        conversation: [
          %{role: "user", content: "Echo twice"},
          %{
            role: "assistant",
            content: nil,
            tool_calls: [
              %{id: "call_1", name: "echo", arguments: %{"message" => "first"}},
              %{id: "call_2", name: "echo", arguments: %{"message" => "second"}}
            ]
          }
        ],
        pending_tool_calls: ["call_1", "call_2"],
        completed_tool_results: [],
        children: %{},
        nodes: %{
          "echo" => %Jido.Composer.Node.ActionNode{
            action_module: EchoAction
          }
        },
        context: Jido.Composer.Context.new()
      }

      restored = checkpoint_and_thaw(orch_state)

      assert length(restored.pending_tool_calls) == 2

      replays = Checkpoint.replay_directives(restored)

      assert length(replays) == 2

      Enum.each(replays, fn replay ->
        assert %Directive.RunInstruction{result_action: :orchestrator_tool_result} = replay
        assert replay.meta.call_id in ["call_1", "call_2"]
        assert replay.meta.tool_name == "echo"
      end)
    end
  end

  # ══════════════════════════════════════════════════════════════
  # ChildRef phase field
  # ══════════════════════════════════════════════════════════════

  describe "ChildRef phase field" do
    test "includes phase field with correct defaults" do
      ref =
        ChildRef.new(
          agent_module: InnerOrchestrator,
          agent_id: "child-phase-test",
          tag: :analyzer,
          status: :running,
          phase: :awaiting_result
        )

      fields = Map.keys(Map.from_struct(ref))
      assert :phase in fields
      assert ref.phase == :awaiting_result

      ref_no_phase =
        ChildRef.new(
          agent_module: InnerOrchestrator,
          agent_id: "child-no-phase",
          tag: :worker,
          status: :running
        )

      assert ref_no_phase.phase == nil
    end

    test "phase falls back from ChildRef when child_phases map is empty" do
      tag = :worker

      child_ref =
        ChildRef.new(
          agent_module: InnerOrchestrator,
          agent_id: "sync-test",
          tag: tag,
          status: :running,
          phase: :awaiting_result
        )

      strat = %{
        children: %{tag => child_ref},
        child_phases: %{tag => :awaiting_result}
      }

      assert strat.children[tag].phase == :awaiting_result
      assert strat.child_phases[tag] == :awaiting_result

      # Backward compat: empty child_phases falls back to ChildRef.phase
      restored = %{
        module: Jido.Composer.Workflow.Strategy,
        children: %{tag => child_ref},
        child_phases: %{}
      }

      # :awaiting_result doesn't generate a replay (only :spawning does)
      replays = Checkpoint.replay_directives(restored)
      assert replays == []

      # :spawning phase on ChildRef triggers SpawnAgent replay
      spawning_ref = %{child_ref | phase: :spawning}

      restored_spawning = %{
        module: Jido.Composer.Workflow.Strategy,
        children: %{tag => spawning_ref},
        child_phases: %{}
      }

      replays = Checkpoint.replay_directives(restored_spawning)
      assert length(replays) == 1
      assert [%Directive.SpawnAgent{agent: InnerOrchestrator, tag: :worker}] = replays
    end
  end

  # ══════════════════════════════════════════════════════════════
  # CheckpointAndStop directive emission
  # ══════════════════════════════════════════════════════════════

  describe "CheckpointAndStop directive emission" do
    test "emitted when suspension timeout exceeds hibernate_after threshold" do
      alias Jido.Composer.Directive.CheckpointAndStop

      agent = init_orchestrator_agent(hibernate_after: 30_000)

      strat = StratState.get(agent)
      assert strat.hibernate_after == 30_000

      # Timeout exceeds threshold → CheckpointAndStop emitted
      {:ok, suspension} = Suspension.new(reason: :rate_limit, timeout: 60_000)
      suspend_directive = %SuspendDirective{suspension: suspension}

      result = Checkpoint.maybe_add_checkpoint_and_stop([suspend_directive], strat)

      assert length(result) == 2
      assert [%SuspendDirective{}, %CheckpointAndStop{suspension: ^suspension}] = result
    end

    test "not emitted when timeout is below threshold" do
      agent = init_orchestrator_agent(hibernate_after: 30_000)
      strat = StratState.get(agent)

      {:ok, short_suspension} = Suspension.new(reason: :rate_limit, timeout: 10_000)
      short_directive = %SuspendDirective{suspension: short_suspension}

      result = Checkpoint.maybe_add_checkpoint_and_stop([short_directive], strat)
      assert length(result) == 1
      assert [%SuspendDirective{}] = result
    end

    test "not emitted when hibernate_after is not configured" do
      agent = init_orchestrator_agent()
      strat = StratState.get(agent)

      {:ok, suspension} = Suspension.new(reason: :rate_limit, timeout: 60_000)
      suspend_directive = %SuspendDirective{suspension: suspension}

      result = Checkpoint.maybe_add_checkpoint_and_stop([suspend_directive], strat)
      assert length(result) == 1
      assert [%SuspendDirective{}] = result
    end
  end

  # ══════════════════════════════════════════════════════════════
  # Suspend directive hibernate serialization
  # ══════════════════════════════════════════════════════════════

  describe "Suspend directive hibernate serialization" do
    test "hibernate field survives checkpoint/thaw round-trip" do
      {:ok, suspension} = Suspension.new(reason: :human_input, timeout: 300_000)

      directive = %SuspendDirective{suspension: suspension, hibernate: true}
      assert directive.hibernate == true

      directive_timed = %SuspendDirective{suspension: suspension, hibernate: %{after: 30_000}}
      assert directive_timed.hibernate == %{after: 30_000}

      # Serialization round-trip
      binary = :erlang.term_to_binary(directive, [:compressed])
      restored = :erlang.binary_to_term(binary)
      assert restored.hibernate == true

      binary_timed = :erlang.term_to_binary(directive_timed, [:compressed])
      restored_timed = :erlang.binary_to_term(binary_timed)
      assert restored_timed.hibernate == %{after: 30_000}
    end
  end

  # ══════════════════════════════════════════════════════════════
  # Gap 4: Suspend DirectiveExec
  # ══════════════════════════════════════════════════════════════

  describe "Suspend DirectiveExec" do
    defp build_exec_state(overrides \\ %{}) do
      %{
        id: Map.get(overrides, :id, "test-exec-1"),
        agent_module: Map.get(overrides, :agent_module, OrchestratorAgent),
        agent: Map.get(overrides, :agent, OrchestratorAgent.new()),
        lifecycle: %{storage: Map.get(overrides, :storage)},
        parent: Map.get(overrides, :parent)
      }
    end

    test "hibernate: false returns {:ok, state}" do
      {:ok, suspension} = Suspension.new(reason: :rate_limit, timeout: 5_000)
      directive = %SuspendDirective{suspension: suspension, hibernate: false}
      state = build_exec_state()

      assert {:ok, ^state} = DirectiveExec.exec(directive, nil, state)
    end

    test "hibernate: true returns {:ok, state}" do
      {:ok, suspension} = Suspension.new(reason: :rate_limit, timeout: 5_000)
      directive = %SuspendDirective{suspension: suspension, hibernate: true}
      state = build_exec_state()

      assert {:ok, ^state} = DirectiveExec.exec(directive, nil, state)
    end

    test "hibernate: %{after: 5000} returns {:ok, state}" do
      {:ok, suspension} = Suspension.new(reason: :rate_limit, timeout: 5_000)
      directive = %SuspendDirective{suspension: suspension, hibernate: %{after: 5000}}
      state = build_exec_state()

      assert {:ok, ^state} = DirectiveExec.exec(directive, nil, state)
    end

    test "invalid hibernate value returns {:ok, state}" do
      {:ok, suspension} = Suspension.new(reason: :rate_limit, timeout: 5_000)
      directive = %SuspendDirective{suspension: suspension, hibernate: :unexpected}
      state = build_exec_state()

      assert {:ok, ^state} = DirectiveExec.exec(directive, nil, state)
    end
  end

  # ══════════════════════════════════════════════════════════════
  # Gap 3: CheckpointAndStop DirectiveExec
  # ══════════════════════════════════════════════════════════════

  describe "CheckpointAndStop DirectiveExec" do
    test "returns {:stop, {:shutdown, :hibernated}, state} with nil storage" do
      {:ok, suspension} = Suspension.new(reason: :rate_limit, timeout: 60_000)
      directive = %CheckpointAndStop{suspension: suspension}
      state = build_exec_state()

      assert {:stop, {:shutdown, :hibernated}, ^state} =
               DirectiveExec.exec(directive, nil, state)
    end

    test "returns {:stop, {:shutdown, :hibernated}, state} with parent notification" do
      {:ok, suspension} = Suspension.new(reason: :rate_limit, timeout: 60_000)
      directive = %CheckpointAndStop{suspension: suspension}

      {:ok, parent_ref} =
        ParentRef.new(%{pid: self(), id: "parent-1", tag: :child, meta: %{}})

      state = build_exec_state(%{parent: parent_ref})

      assert {:stop, {:shutdown, :hibernated}, ^state} =
               DirectiveExec.exec(directive, nil, state)

      assert_receive {:"$gen_cast", {:signal, signal}}
      assert signal.type == "composer.child.hibernated"
      assert signal.data.tag == :child
    end

    test "no crash when parent is nil" do
      {:ok, suspension} = Suspension.new(reason: :rate_limit, timeout: 60_000)
      directive = %CheckpointAndStop{suspension: suspension}
      state = build_exec_state(%{parent: nil})

      assert {:stop, {:shutdown, :hibernated}, ^state} =
               DirectiveExec.exec(directive, nil, state)
    end
  end

  # ══════════════════════════════════════════════════════════════
  # Gap 2: AgentNode tool replay
  # ══════════════════════════════════════════════════════════════

  describe "AgentNode tool replay" do
    test "replay emits SpawnAgent for AgentNode pending tool calls" do
      orch_state = %{
        module: Jido.Composer.Orchestrator.Strategy,
        status: :awaiting_tool,
        conversation: [
          %{role: "user", content: "Run agent"},
          %{
            role: "assistant",
            content: nil,
            tool_calls: [
              %{id: "call_1", name: "agent_tool", arguments: %{"query" => "hello"}}
            ]
          }
        ],
        pending_tool_calls: ["call_1"],
        completed_tool_results: [],
        children: %{},
        nodes: %{
          "agent_tool" => %AgentNode{agent_module: InnerOrchestrator, opts: []}
        },
        context: Context.new()
      }

      replays = Checkpoint.replay_directives(orch_state)

      assert length(replays) == 1

      assert [
               %Directive.SpawnAgent{
                 agent: InnerOrchestrator,
                 tag: {:tool_call, "call_1", "agent_tool"}
               }
             ] = replays
    end

    test "replay emits mixed directives for ActionNode and AgentNode" do
      orch_state = %{
        module: Jido.Composer.Orchestrator.Strategy,
        status: :awaiting_tools,
        conversation: [
          %{role: "user", content: "Run both"},
          %{
            role: "assistant",
            content: nil,
            tool_calls: [
              %{id: "call_1", name: "echo", arguments: %{"message" => "hello"}},
              %{id: "call_2", name: "agent_tool", arguments: %{"query" => "world"}}
            ]
          }
        ],
        pending_tool_calls: ["call_1", "call_2"],
        completed_tool_results: [],
        children: %{},
        nodes: %{
          "echo" => %Jido.Composer.Node.ActionNode{action_module: EchoAction},
          "agent_tool" => %AgentNode{agent_module: InnerOrchestrator, opts: []}
        },
        context: Context.new()
      }

      replays = Checkpoint.replay_directives(orch_state)

      assert length(replays) == 2

      run_instructions = Enum.filter(replays, &match?(%Directive.RunInstruction{}, &1))
      spawn_agents = Enum.filter(replays, &match?(%Directive.SpawnAgent{}, &1))

      assert length(run_instructions) == 1
      assert length(spawn_agents) == 1

      [%Directive.RunInstruction{meta: meta}] = run_instructions
      assert meta.call_id == "call_1"
      assert meta.tool_name == "echo"

      [%Directive.SpawnAgent{agent: InnerOrchestrator, tag: {:tool_call, "call_2", "agent_tool"}}] =
        spawn_agents
    end
  end

  # ══════════════════════════════════════════════════════════════
  # Gap 1: awaiting_tools_and_approval checkpoint/replay
  # ══════════════════════════════════════════════════════════════

  describe "awaiting_tools_and_approval checkpoint/replay" do
    test "combined state survives checkpoint/thaw" do
      agent = init_orchestrator_agent(nodes: [EchoAction, NoopAction], gated_nodes: ["echo"])

      # LLM returns tool calls for both echo (gated) and noop (ungated)
      tool_calls = [
        %{id: "call_echo", name: "echo", arguments: %{"message" => "gated"}},
        %{id: "call_noop", name: "noop", arguments: %{}}
      ]

      LLMStub.setup([{:tool_calls, tool_calls}])

      # Start orchestrator — emits LLM RunInstruction
      {agent, directives} =
        OrchStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_start, %{query: "Run both tools"})],
          %{}
        )

      # Execute only the LLM directive — feed its result back to strategy
      assert [%Directive.RunInstruction{instruction: llm_instr, result_action: result_action}] =
               directives

      payload = execute_llm(llm_instr)

      {agent, _tool_directives} =
        OrchStrategy.cmd(agent, [make_instruction(result_action, payload)], %{})

      # Now strategy has dispatched tool calls: noop ungated, echo gated
      strat = StratState.get(agent)
      assert strat.status == :awaiting_tools_and_approval
      assert "call_noop" in strat.pending_tool_calls
      assert map_size(strat.gated_calls) == 1

      # Checkpoint/thaw
      restored = checkpoint_and_thaw(strat)

      assert restored.status == :awaiting_tools_and_approval
      assert "call_noop" in restored.pending_tool_calls
      assert map_size(restored.gated_calls) == 1
    end

    test "replay_directives emits RunInstruction for ungated tools only" do
      orch_state = %{
        module: Jido.Composer.Orchestrator.Strategy,
        status: :awaiting_tools_and_approval,
        conversation: [
          %{role: "user", content: "Run both"},
          %{
            role: "assistant",
            content: nil,
            tool_calls: [
              %{id: "call_echo", name: "echo", arguments: %{"message" => "gated"}},
              %{id: "call_noop", name: "noop", arguments: %{}}
            ]
          }
        ],
        pending_tool_calls: ["call_noop"],
        completed_tool_results: [],
        children: %{},
        gated_calls: %{
          "req_1" => %{
            request: %{id: "req_1"},
            call: %{id: "call_echo", name: "echo", arguments: %{"message" => "gated"}}
          }
        },
        nodes: %{
          "echo" => %Jido.Composer.Node.ActionNode{action_module: EchoAction},
          "noop" => %Jido.Composer.Node.ActionNode{action_module: NoopAction}
        },
        context: Context.new()
      }

      replays = Checkpoint.replay_directives(orch_state)

      # Only the ungated pending_tool_calls should be replayed
      assert length(replays) == 1
      assert [%Directive.RunInstruction{meta: meta}] = replays
      assert meta.call_id == "call_noop"
      assert meta.tool_name == "noop"
    end
  end

  # ══════════════════════════════════════════════════════════════
  # Gap 5: Orchestrator suspended_calls checkpoint/resume
  # ══════════════════════════════════════════════════════════════

  describe "orchestrator suspended_calls checkpoint/resume" do
    test "suspended_calls survives checkpoint/thaw" do
      agent = init_orchestrator_agent()

      tool_call = %{id: "call_1", name: "echo", arguments: %{"message" => "suspend me"}}
      LLMStub.setup([{:tool_calls, [tool_call]}])

      # Start orchestrator and execute LLM directive
      {agent, directives} =
        OrchStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_start, %{query: "Echo"})],
          %{}
        )

      {agent, _remaining} = execute_orchestrator_directives(agent, directives)

      # Feed tool result with status: :suspend
      {agent, _directives} =
        OrchStrategy.cmd(
          agent,
          [
            make_instruction(:orchestrator_tool_result, %{
              status: :suspend,
              reason: :rate_limit,
              meta: %{call_id: "call_1", tool_name: "echo"}
            })
          ],
          %{}
        )

      strat = StratState.get(agent)
      assert strat.status == :awaiting_suspension
      assert map_size(strat.suspended_calls) == 1

      # Checkpoint/thaw
      restored = checkpoint_and_thaw(strat)

      assert restored.status == :awaiting_suspension
      assert map_size(restored.suspended_calls) == 1

      [{suspension_id, entry}] = Map.to_list(restored.suspended_calls)
      assert entry.call.id == "call_1"
      assert entry.call.name == "echo"
      assert entry.suspension.reason == :rate_limit
      assert is_binary(suspension_id)
    end

    test "suspend_resume with data provides direct tool result" do
      agent = init_orchestrator_agent()

      tool_call = %{id: "call_1", name: "echo", arguments: %{"message" => "suspend me"}}
      LLMStub.setup([{:tool_calls, [tool_call]}])

      {agent, directives} =
        OrchStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_start, %{query: "Echo"})],
          %{}
        )

      {agent, _remaining} = execute_orchestrator_directives(agent, directives)

      # Feed tool result with status: :suspend
      {agent, _directives} =
        OrchStrategy.cmd(
          agent,
          [
            make_instruction(:orchestrator_tool_result, %{
              status: :suspend,
              reason: :rate_limit,
              meta: %{call_id: "call_1", tool_name: "echo"}
            })
          ],
          %{}
        )

      strat = StratState.get(agent)
      [{suspension_id, _entry}] = Map.to_list(strat.suspended_calls)

      # Resume with data — triggers check_all_tools_done → awaiting_llm → LLM call
      LLMStub.setup([{:final_answer, "Resumed successfully"}])

      {agent, directives} =
        OrchStrategy.cmd(
          agent,
          [
            make_instruction(:suspend_resume, %{
              suspension_id: suspension_id,
              outcome: :ok,
              data: %{result: "done"}
            })
          ],
          %{}
        )

      strat = StratState.get(agent)
      assert strat.suspended_calls == %{}

      # Execute the follow-up LLM call to completion
      {final_agent, _} = execute_orchestrator_directives(agent, directives)
      final_strat = StratState.get(final_agent)
      assert final_strat.status == :completed
      assert final_strat.result.value == "Resumed successfully"
    end

    test "suspend_resume without data re-dispatches tool" do
      agent = init_orchestrator_agent()

      tool_call = %{id: "call_1", name: "echo", arguments: %{"message" => "suspend me"}}
      LLMStub.setup([{:tool_calls, [tool_call]}])

      {agent, directives} =
        OrchStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_start, %{query: "Echo"})],
          %{}
        )

      {agent, _remaining} = execute_orchestrator_directives(agent, directives)

      # Feed tool result with status: :suspend
      {agent, _directives} =
        OrchStrategy.cmd(
          agent,
          [
            make_instruction(:orchestrator_tool_result, %{
              status: :suspend,
              reason: :rate_limit,
              meta: %{call_id: "call_1", tool_name: "echo"}
            })
          ],
          %{}
        )

      strat = StratState.get(agent)
      [{suspension_id, _entry}] = Map.to_list(strat.suspended_calls)

      # Resume without data — re-dispatches the tool call
      {agent, directives} =
        OrchStrategy.cmd(
          agent,
          [
            make_instruction(:suspend_resume, %{
              suspension_id: suspension_id,
              outcome: :ok
            })
          ],
          %{}
        )

      strat = StratState.get(agent)
      assert strat.suspended_calls == %{}
      assert "call_1" in strat.pending_tool_calls

      # Should have a RunInstruction directive for re-dispatch
      assert length(directives) == 1

      assert [%Directive.RunInstruction{result_action: :orchestrator_tool_result} = directive] =
               directives

      assert directive.meta.call_id == "call_1"
      assert directive.meta.tool_name == "echo"
    end
  end
end
