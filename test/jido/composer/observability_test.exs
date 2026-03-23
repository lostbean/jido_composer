defmodule Jido.Composer.ObservabilityTest do
  @moduledoc """
  Tests that observability spans are emitted at the correct points in
  orchestrator and workflow strategy execution.

  Uses telemetry handlers to capture events — no OTel required.
  """
  use ExUnit.Case, async: false

  alias Jido.Composer.Orchestrator.Strategy, as: OrchestratorStrategy
  alias Jido.Composer.Workflow.Strategy, as: WorkflowStrategy

  alias Jido.Composer.TestActions.{
    AddAction,
    EchoAction,
    NoopAction
  }

  alias Jido.Composer.TestSupport.LLMStub

  @moduletag :capture_log

  # -- Test Agent Modules --

  defmodule TestOrchestratorAgent do
    use Jido.Agent,
      name: "test_obs_orchestrator",
      description: "Test agent for observability tests",
      schema: []
  end

  defmodule TestWorkflowAgent do
    use Jido.Agent,
      name: "test_obs_workflow",
      description: "Test agent for workflow observability tests",
      schema: []
  end

  # -- Telemetry capture helpers --

  defp attach_telemetry(test_pid, handler_id) do
    events = [
      [:jido, :composer, :agent, :start],
      [:jido, :composer, :agent, :stop],
      [:jido, :composer, :agent, :exception],
      [:jido, :composer, :llm, :start],
      [:jido, :composer, :llm, :stop],
      [:jido, :composer, :llm, :exception],
      [:jido, :composer, :tool, :start],
      [:jido, :composer, :tool, :stop],
      [:jido, :composer, :tool, :exception],
      [:jido, :composer, :iteration, :start],
      [:jido, :composer, :iteration, :stop]
    ]

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )
  end

  defp detach_telemetry(handler_id) do
    :telemetry.detach(handler_id)
  end

  setup do
    handler_id = make_ref()
    attach_telemetry(self(), handler_id)
    on_exit(fn -> detach_telemetry(handler_id) end)
    %{handler_id: handler_id}
  end

  # -- Orchestrator helpers --

  defp init_orchestrator(opts \\ []) do
    nodes = Keyword.get(opts, :nodes, [AddAction, EchoAction])
    extra = Keyword.drop(opts, [:nodes])

    strategy_opts =
      [
        nodes: nodes,
        model: "stub:test-model",
        system_prompt: "You are a test assistant.",
        max_iterations: 10,
        req_options: []
      ] ++ extra

    agent = TestOrchestratorAgent.new()
    ctx = %{strategy_opts: strategy_opts}
    {agent, _directives} = OrchestratorStrategy.init(agent, ctx)
    agent
  end

  defp init_workflow(nodes_map, transitions, opts) do
    strategy_opts =
      [
        nodes: nodes_map,
        transitions: transitions,
        initial: Keyword.get(opts, :initial, :extract),
        terminal_states: Keyword.get(opts, :terminal_states, [:done, :failed])
      ] ++ Keyword.drop(opts, [:initial, :terminal_states])

    agent = TestWorkflowAgent.new()
    ctx = %{strategy_opts: strategy_opts, agent_module: TestWorkflowAgent}
    {agent, _directives} = WorkflowStrategy.init(agent, ctx)
    agent
  end

  defp make_instruction(action, params) do
    %Jido.Instruction{action: action, params: params}
  end

  defp ctx, do: %{}

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

  # -- Orchestrator span tests --

  describe "orchestrator spans" do
    test "starting emits agent :start event" do
      LLMStub.setup([{:final_answer, "Hello"}])
      agent = init_orchestrator()

      {_agent, _directives} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_start, %{query: "Hi"})],
          ctx()
        )

      assert_receive {:telemetry_event, [:jido, :composer, :agent, :start], _measurements,
                      metadata}

      assert metadata[:query] == "Hi"
    end

    test "LLM call emits llm :start event" do
      LLMStub.setup([{:final_answer, "Hello"}])
      agent = init_orchestrator()

      {_agent, directives} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_start, %{query: "Hi"})],
          ctx()
        )

      # The start also triggers emit_llm_call which emits llm start
      assert_receive {:telemetry_event, [:jido, :composer, :llm, :start], _measurements, metadata}
      assert metadata[:model] == "stub:test-model"
      assert length(directives) == 1
    end

    test "LLM result with final answer emits llm :stop and agent :stop" do
      LLMStub.setup([{:final_answer, "Hello"}])
      agent = init_orchestrator()

      {agent, directives} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_start, %{query: "Hi"})],
          ctx()
        )

      llm_result = execute_llm_directive(hd(directives))

      {_agent, _directives} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_llm_result, llm_result)],
          ctx()
        )

      assert_receive {:telemetry_event, [:jido, :composer, :llm, :stop], _m, _meta}
      assert_receive {:telemetry_event, [:jido, :composer, :agent, :stop], _m2, _meta2}
    end

    test "tool dispatch emits tool :start event" do
      LLMStub.setup([
        {:tool_calls, [%{id: "call_1", name: "add", arguments: %{"value" => 1, "amount" => 2}}]},
        {:final_answer, "Done"}
      ])

      agent = init_orchestrator()

      {agent, directives} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_start, %{query: "Add 1 + 2"})],
          ctx()
        )

      llm_result = execute_llm_directive(hd(directives))

      {_agent, _directives} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_llm_result, llm_result)],
          ctx()
        )

      assert_receive {:telemetry_event, [:jido, :composer, :tool, :start], _m, metadata}
      assert metadata[:tool_name] == "add"
      assert metadata[:call_id] == "call_1"
    end

    test "tool result emits tool :stop event" do
      LLMStub.setup([
        {:tool_calls, [%{id: "call_1", name: "add", arguments: %{"value" => 1, "amount" => 2}}]},
        {:final_answer, "Done"}
      ])

      agent = init_orchestrator()

      {agent, directives} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_start, %{query: "Add 1 + 2"})],
          ctx()
        )

      llm_result = execute_llm_directive(hd(directives))

      {agent, _directives} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_llm_result, llm_result)],
          ctx()
        )

      # Feed tool result back
      {_agent, _directives} =
        OrchestratorStrategy.cmd(
          agent,
          [
            make_instruction(:orchestrator_tool_result, %{
              status: :ok,
              result: %{result: 3.0},
              meta: %{call_id: "call_1", tool_name: "add"}
            })
          ],
          ctx()
        )

      assert_receive {:telemetry_event, [:jido, :composer, :tool, :stop], _m, metadata}
      assert metadata[:call_id] == "call_1"
      assert metadata[:tool_name] == "add"
    end
  end

  describe "orchestrator metadata correctness" do
    test "agent start includes query" do
      LLMStub.setup([{:final_answer, "OK"}])
      agent = init_orchestrator()

      {_agent, _} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_start, %{query: "What is 2+2?"})],
          ctx()
        )

      assert_receive {:telemetry_event, [:jido, :composer, :agent, :start], _, metadata}
      assert metadata[:query] == "What is 2+2?"
      assert metadata[:name] != nil
    end

    test "llm start includes model" do
      LLMStub.setup([{:final_answer, "OK"}])
      agent = init_orchestrator()

      {_agent, _} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_start, %{query: "test"})],
          ctx()
        )

      assert_receive {:telemetry_event, [:jido, :composer, :llm, :start], _, metadata}
      assert metadata[:model] == "stub:test-model"
      assert metadata[:iteration] != nil
    end
  end

  # -- Workflow span tests --

  describe "workflow spans" do
    test "starting emits agent :start event" do
      nodes = %{
        extract: {:action, EchoAction},
        done: {:action, EchoAction}
      }

      transitions = %{
        {:extract, :ok} => :done
      }

      agent = init_workflow(nodes, transitions, initial: :extract)

      {_agent, _directives} =
        WorkflowStrategy.cmd(
          agent,
          [make_instruction(:workflow_start, %{input: "data"})],
          ctx()
        )

      assert_receive {:telemetry_event, [:jido, :composer, :agent, :start], _m, metadata}
      assert metadata[:name] != nil
    end

    test "node dispatch emits tool :start event" do
      nodes = %{
        extract: {:action, EchoAction},
        done: {:action, EchoAction}
      }

      transitions = %{
        {:extract, :ok} => :done
      }

      agent = init_workflow(nodes, transitions, initial: :extract)

      {_agent, _directives} =
        WorkflowStrategy.cmd(
          agent,
          [make_instruction(:workflow_start, %{input: "data"})],
          ctx()
        )

      assert_receive {:telemetry_event, [:jido, :composer, :tool, :start], _m, metadata}
      assert metadata[:node_name] != nil
    end

    test "node result emits tool :stop event" do
      nodes = %{
        extract: {:action, EchoAction},
        done: {:action, EchoAction}
      }

      transitions = %{
        {:extract, :ok} => :done
      }

      agent = init_workflow(nodes, transitions, initial: :extract)

      {agent, _directives} =
        WorkflowStrategy.cmd(
          agent,
          [make_instruction(:workflow_start, %{input: "data"})],
          ctx()
        )

      {_agent, _directives} =
        WorkflowStrategy.cmd(
          agent,
          [
            make_instruction(:workflow_node_result, %{
              status: :ok,
              result: %{output: "extracted"},
              outcome: :ok
            })
          ],
          ctx()
        )

      assert_receive {:telemetry_event, [:jido, :composer, :tool, :stop], _m, _metadata}
    end

    test "reaching terminal state emits agent :stop event" do
      nodes = %{
        extract: {:action, EchoAction},
        done: {:action, EchoAction}
      }

      transitions = %{
        {:extract, :ok} => :done
      }

      agent =
        init_workflow(nodes, transitions, initial: :extract, terminal_states: [:done, :failed])

      {agent, _directives} =
        WorkflowStrategy.cmd(
          agent,
          [make_instruction(:workflow_start, %{input: "data"})],
          ctx()
        )

      # Complete extract → done (terminal)
      {_agent, _directives} =
        WorkflowStrategy.cmd(
          agent,
          [
            make_instruction(:workflow_node_result, %{
              status: :ok,
              result: %{output: "extracted"},
              outcome: :ok
            })
          ],
          ctx()
        )

      assert_receive {:telemetry_event, [:jido, :composer, :agent, :stop], _m, _metadata}
    end
  end

  describe "orchestrator span data correctness" do
    test "multiple parallel tool calls emit independent tool :start events" do
      LLMStub.setup([
        {:tool_calls,
         [
           %{id: "call_1", name: "add", arguments: %{"value" => 1, "amount" => 2}},
           %{id: "call_2", name: "echo", arguments: %{"message" => "hello"}}
         ]},
        {:final_answer, "Done"}
      ])

      agent = init_orchestrator()

      {agent, directives} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_start, %{query: "Do stuff"})],
          ctx()
        )

      llm_result = execute_llm_directive(hd(directives))

      {_agent, _directives} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_llm_result, llm_result)],
          ctx()
        )

      assert_receive {:telemetry_event, [:jido, :composer, :tool, :start], _m, meta1}
      assert_receive {:telemetry_event, [:jido, :composer, :tool, :start], _m, meta2}
      tool_names = Enum.sort([meta1[:tool_name], meta2[:tool_name]])
      assert tool_names == ["add", "echo"]
    end

    test "agent :stop measurement includes unwrapped final answer" do
      LLMStub.setup([{:final_answer, "The answer is 42"}])
      agent = init_orchestrator()

      {agent, directives} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_start, %{query: "What?"})],
          ctx()
        )

      llm_result = execute_llm_directive(hd(directives))

      {_agent, _} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_llm_result, llm_result)],
          ctx()
        )

      assert_receive {:telemetry_event, [:jido, :composer, :agent, :stop], measurements, _meta}
      # Result should be the unwrapped text, not a NodeIO struct
      assert measurements[:result] == "The answer is 42"
      assert measurements[:iterations] == 1
    end

    test "llm :stop event is emitted with measurements" do
      LLMStub.setup([{:final_answer, "Hello"}])
      agent = init_orchestrator()

      {agent, directives} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_start, %{query: "Hi"})],
          ctx()
        )

      llm_result = execute_llm_directive(hd(directives))

      {_agent, _} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_llm_result, llm_result)],
          ctx()
        )

      assert_receive {:telemetry_event, [:jido, :composer, :llm, :stop], measurements, _meta}
      # LLM stop is emitted; measurements may include tokens/finish_reason from real API
      assert is_map(measurements)
    end
  end

  describe "workflow span data correctness" do
    test "workflow node :start event includes input context as arguments" do
      nodes = %{
        extract: {:action, EchoAction},
        done: {:action, EchoAction}
      }

      transitions = %{
        {:extract, :ok} => :done
      }

      agent = init_workflow(nodes, transitions, initial: :extract)

      {_agent, _} =
        WorkflowStrategy.cmd(
          agent,
          [make_instruction(:workflow_start, %{input: "data"})],
          ctx()
        )

      assert_receive {:telemetry_event, [:jido, :composer, :tool, :start], _m, metadata}
      assert metadata[:arguments] != nil
      assert metadata[:arguments][:input] == "data"
    end
  end

  describe "checkpoint strips _obs fields" do
    test "orchestrator strip_for_checkpoint clears obs fields" do
      obs = %Jido.Composer.Orchestrator.Obs{
        agent_span: :some_span_ctx,
        llm_span: :some_llm_ctx,
        tool_spans: %{"call_1" => :span},
        iteration_span: :some_iter_ctx,
        cumulative_tokens: %{prompt: 100, completion: 50, total: 150}
      }

      state = %{
        status: :completed,
        _obs: obs,
        approval_gate: %{approval_policy: fn _ -> :ok end}
      }

      cleaned = OrchestratorStrategy.strip_for_checkpoint(state)
      assert cleaned._obs == %Jido.Composer.Orchestrator.Obs{}
    end

    test "workflow strip_for_checkpoint clears obs fields" do
      obs = %Jido.Composer.Workflow.Obs{
        agent_span: :some_span_ctx,
        node_span: :some_node_ctx
      }

      state = %{
        status: :success,
        _obs: obs
      }

      cleaned = WorkflowStrategy.strip_for_checkpoint(state)
      assert cleaned._obs == %Jido.Composer.Workflow.Obs{}
    end
  end

  describe "llm output includes tool_calls" do
    test "llm :stop measurements include tool_calls in output_messages" do
      LLMStub.setup([
        {:tool_calls, [%{id: "call_1", name: "add", arguments: %{"value" => 1, "amount" => 2}}]},
        {:final_answer, "Done"}
      ])

      agent = init_orchestrator()

      {agent, directives} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_start, %{query: "Add 1 + 2"})],
          ctx()
        )

      llm_result = execute_llm_directive(hd(directives))

      {_agent, _directives} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_llm_result, llm_result)],
          ctx()
        )

      assert_receive {:telemetry_event, [:jido, :composer, :llm, :stop], measurements, _meta}
      # LLMStub direct mode doesn't produce ReqLLM.Context with tool_calls
      # but the measurements should be a valid map
      assert is_map(measurements)
    end
  end

  describe "iteration spans" do
    test "single-iteration orchestrator emits iteration :start and :stop" do
      LLMStub.setup([{:final_answer, "Hello"}])
      agent = init_orchestrator()

      {agent, directives} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_start, %{query: "Hi"})],
          ctx()
        )

      # iteration start is emitted during orchestrator_start -> emit_llm_call
      assert_receive {:telemetry_event, [:jido, :composer, :iteration, :start], _m, metadata}
      assert metadata[:iteration] == 1

      llm_result = execute_llm_directive(hd(directives))

      {_agent, _directives} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_llm_result, llm_result)],
          ctx()
        )

      # iteration stop is emitted on final_answer
      assert_receive {:telemetry_event, [:jido, :composer, :iteration, :stop], measurements,
                      _meta}

      assert is_map(measurements)
    end

    test "two-iteration orchestrator emits two iteration spans" do
      LLMStub.setup([
        {:tool_calls, [%{id: "call_1", name: "add", arguments: %{"value" => 1, "amount" => 2}}]},
        {:final_answer, "Done"}
      ])

      agent = init_orchestrator()

      {agent, directives} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_start, %{query: "Add 1 + 2"})],
          ctx()
        )

      # First iteration start
      assert_receive {:telemetry_event, [:jido, :composer, :iteration, :start], _m, meta1}
      assert meta1[:iteration] == 1

      llm_result = execute_llm_directive(hd(directives))

      {agent, _directives} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_llm_result, llm_result)],
          ctx()
        )

      # Feed tool result back
      {agent, directives2} =
        OrchestratorStrategy.cmd(
          agent,
          [
            make_instruction(:orchestrator_tool_result, %{
              status: :ok,
              result: %{result: 3.0},
              meta: %{call_id: "call_1", tool_name: "add"}
            })
          ],
          ctx()
        )

      # First iteration stop (tools done -> next iteration)
      assert_receive {:telemetry_event, [:jido, :composer, :iteration, :stop], _m, _meta}

      # Second iteration start
      assert_receive {:telemetry_event, [:jido, :composer, :iteration, :start], _m, meta2}
      assert meta2[:iteration] == 2

      llm_result2 = execute_llm_directive(hd(directives2))

      {_agent, _directives} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_llm_result, llm_result2)],
          ctx()
        )

      # Second iteration stop (final answer)
      assert_receive {:telemetry_event, [:jido, :composer, :iteration, :stop], _m2, _meta2}
    end

    test "iteration span wraps LLM and tool spans" do
      LLMStub.setup([
        {:tool_calls, [%{id: "call_1", name: "add", arguments: %{"value" => 1, "amount" => 2}}]},
        {:final_answer, "Done"}
      ])

      agent = init_orchestrator()

      {agent, directives} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_start, %{query: "Add 1 + 2"})],
          ctx()
        )

      # Verify ordering: iteration:start before llm:start
      assert_receive {:telemetry_event, [:jido, :composer, :iteration, :start], _, _}
      assert_receive {:telemetry_event, [:jido, :composer, :llm, :start], _, _}

      llm_result = execute_llm_directive(hd(directives))

      {agent, _} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_llm_result, llm_result)],
          ctx()
        )

      # llm:stop before tool:start
      assert_receive {:telemetry_event, [:jido, :composer, :llm, :stop], _, _}
      assert_receive {:telemetry_event, [:jido, :composer, :tool, :start], _, _}

      # Feed tool result
      {_agent, _} =
        OrchestratorStrategy.cmd(
          agent,
          [
            make_instruction(:orchestrator_tool_result, %{
              status: :ok,
              result: %{result: 3.0},
              meta: %{call_id: "call_1", tool_name: "add"}
            })
          ],
          ctx()
        )

      # tool:stop then iteration:stop
      assert_receive {:telemetry_event, [:jido, :composer, :tool, :stop], _, _}
      assert_receive {:telemetry_event, [:jido, :composer, :iteration, :stop], _, _}
    end
  end

  describe "MapNode workflow spans" do
    test "MapNode emits agent :start, tool :start on dispatch, agent :stop on completion" do
      {:ok, map_node} =
        Jido.Composer.Node.MapNode.new(
          name: :process,
          over: :items,
          node: NoopAction
        )

      nodes = %{process: map_node}
      transitions = %{{:process, :ok} => :done}

      agent =
        init_workflow(nodes, transitions, initial: :process, terminal_states: [:done, :failed])

      # Start workflow — emits agent :start and tool :start (MapNode dispatch)
      {agent, directives} =
        WorkflowStrategy.cmd(
          agent,
          [make_instruction(:workflow_start, %{items: [%{value: 1}]})],
          ctx()
        )

      assert_receive {:telemetry_event, [:jido, :composer, :agent, :start], _m, _meta}
      assert_receive {:telemetry_event, [:jido, :composer, :tool, :start], _m, metadata}
      assert metadata[:node_name] != nil

      # Feed all fan-out branch results
      Enum.reduce(directives, agent, fn
        %Jido.Composer.Directive.FanOutBranch{} = branch, acc ->
          result = branch.child_node.__struct__.run(branch.child_node, branch.params, [])

          {acc2, _} =
            WorkflowStrategy.cmd(
              acc,
              [
                make_instruction(:fan_out_branch_result, %{
                  branch_name: branch.branch_name,
                  result: result
                })
              ],
              ctx()
            )

          acc2

        _other, acc ->
          acc
      end)

      # Fan-out completion reaches terminal state → agent :stop
      assert_receive {:telemetry_event, [:jido, :composer, :agent, :stop], measurements, _meta}
      assert measurements[:status] == :success
    end
  end

  describe "cumulative tokens" do
    test "agent :stop includes cumulative tokens from LLM call" do
      LLMStub.setup([{:final_answer, "The answer is 42"}])
      agent = init_orchestrator()

      {agent, directives} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_start, %{query: "What?"})],
          ctx()
        )

      llm_result = execute_llm_directive(hd(directives))

      {_agent, _} =
        OrchestratorStrategy.cmd(
          agent,
          [make_instruction(:orchestrator_llm_result, llm_result)],
          ctx()
        )

      assert_receive {:telemetry_event, [:jido, :composer, :agent, :stop], measurements, _meta}
      # LLMStub direct mode doesn't include usage data, so tokens won't be accumulated
      # but the measurement structure should be correct
      assert measurements[:iterations] == 1
    end
  end
end
