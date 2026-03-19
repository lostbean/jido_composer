defmodule Jido.Composer.Workflow.DSLTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.TestActions.{AddAction, MultiplyAction}

  defmodule SimpleWorkflow do
    use Jido.Composer.Workflow,
      name: "simple_workflow",
      description: "A simple two-step workflow",
      nodes: %{
        extract: AddAction,
        transform: MultiplyAction
      },
      transitions: %{
        {:extract, :ok} => :transform,
        {:transform, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :extract
  end

  describe "module generation" do
    test "generates a module that can create an agent" do
      agent = SimpleWorkflow.new()
      assert agent.name == "simple_workflow"
    end

    test "agent has workflow strategy configured" do
      assert SimpleWorkflow.strategy() == Jido.Composer.Workflow.Strategy
    end

    test "strategy_opts contain node specs, transitions, and initial state" do
      opts = SimpleWorkflow.strategy_opts()
      assert is_map(opts[:nodes])
      assert is_map(opts[:transitions])
      assert opts[:initial] == :extract
    end
  end

  describe "node auto-wrapping" do
    test "bare action modules are tagged as {:action, Module}" do
      opts = SimpleWorkflow.strategy_opts()
      assert {:action, AddAction} = opts[:nodes][:extract]
      assert {:action, MultiplyAction} = opts[:nodes][:transform]
    end
  end

  describe "signal routes" do
    test "generated module declares workflow signal routes" do
      routes = SimpleWorkflow.signal_routes()
      route_types = Enum.map(routes, fn {type, _target} -> type end)
      assert "composer.workflow.start" in route_types
    end
  end

  describe "workflow execution" do
    test "run/2 starts the workflow with initial context" do
      agent = SimpleWorkflow.new()
      {agent, directives} = SimpleWorkflow.run(agent, %{value: 1.0, amount: 2.0})

      assert [%Jido.Agent.Directive.RunInstruction{}] = directives
      assert agent.state.__strategy__.machine.status == :extract
    end

    test "run_sync/2 blocks until terminal state and returns result" do
      agent = SimpleWorkflow.new()
      assert {:ok, result} = SimpleWorkflow.run_sync(agent, %{value: 1.0, amount: 2.0})
      assert is_map(result)
      assert result[:extract][:result] == 3.0
    end
  end

  describe "node auto-detection" do
    defmodule ActionWithOptsWorkflow do
      use Jido.Composer.Workflow,
        name: "action_opts_workflow",
        nodes: %{
          step_a: {AddAction, [timeout: 5000]},
          step_b: MultiplyAction
        },
        transitions: %{
          {:step_a, :ok} => :step_b,
          {:step_b, :ok} => :done,
          {:_, :error} => :failed
        },
        initial: :step_a
    end

    test "action module with opts is wrapped as action, not agent" do
      opts = ActionWithOptsWorkflow.strategy_opts()
      # An action module with opts should auto-detect as action
      assert {:action, AddAction} = opts[:nodes][:step_a]
    end

    test "agent module is detected and wrapped as agent" do
      # Modules responding to __agent_metadata__/0 should wrap as agent
      nodes_raw = %{step: {Jido.Composer.TestAgents.EchoAgent, []}}
      wrapped = Jido.Composer.Workflow.DSL.__wrap_nodes__(nodes_raw)
      assert {:agent, Jido.Composer.TestAgents.EchoAgent, []} = wrapped[:step]
    end
  end

  describe "compile-time warnings" do
    test "warns about unreachable states" do
      warnings =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          defmodule UnreachableWorkflow do
            use Jido.Composer.Workflow,
              name: "unreachable",
              nodes: %{
                step_a: AddAction,
                step_b: MultiplyAction,
                orphan: AddAction
              },
              transitions: %{
                {:step_a, :ok} => :step_b,
                {:step_b, :ok} => :done,
                {:_, :error} => :failed
              },
              initial: :step_a
          end
        end)

      assert warnings =~ "orphan"
      assert warnings =~ "unreachable"
    end

    test "warns when :suspend is used as a transition outcome" do
      warnings =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          defmodule SuspendOutcomeWorkflow do
            use Jido.Composer.Workflow,
              name: "suspend_outcome",
              nodes: %{
                step_a: AddAction,
                step_b: MultiplyAction
              },
              transitions: %{
                {:step_a, :ok} => :step_b,
                {:step_a, :suspend} => :step_b,
                {:step_b, :ok} => :done,
                {:_, :error} => :failed
              },
              initial: :step_a
          end
        end)

      assert warnings =~ "unreachable"
      assert warnings =~ ":suspend"
      assert warnings =~ "reserved outcome"
    end

    test "warns about non-terminal states with no outgoing transitions" do
      warnings =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          defmodule DeadEndWorkflow do
            use Jido.Composer.Workflow,
              name: "dead_end",
              nodes: %{
                step_a: AddAction,
                step_b: MultiplyAction
              },
              transitions: %{
                {:step_a, :ok} => :step_b,
                {:_, :error} => :failed
              },
              initial: :step_a
          end
        end)

      assert warnings =~ "step_b"
      assert warnings =~ "no outgoing transition"
    end
  end

  describe "SpawnAgent directive handling" do
    defmodule WorkflowWithNestedWorkflow do
      use Jido.Composer.Workflow,
        name: "workflow_with_nested",
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

    test "run_sync handles SpawnAgent directives for workflow agents" do
      agent = WorkflowWithNestedWorkflow.new()

      assert {:ok, result} =
               WorkflowWithNestedWorkflow.run_sync(agent, %{source: "test_db"})

      assert is_map(result)
      # The nested workflow should have run and its result should be scoped
      assert Map.has_key?(result, :nested)
      # The nested workflow ran transform + load internally
      nested = result[:nested]
      assert nested[:load][:status] == :complete
    end
  end

  describe "FanOutBranch directive handling" do
    alias Jido.Composer.Node.{ActionNode, FanOutNode}

    defmodule FanOutDSLWorkflow do
      {:ok, add_node} = ActionNode.new(AddAction)
      {:ok, echo_node} = ActionNode.new(Jido.Composer.TestActions.EchoAction)

      {:ok, fan_out} =
        FanOutNode.new(
          name: "parallel",
          branches: [add: add_node, echo: echo_node]
        )

      use Jido.Composer.Workflow,
        name: "fan_out_dsl_workflow",
        nodes: %{
          compute: fan_out
        },
        transitions: %{
          {:compute, :ok} => :done,
          {:_, :error} => :failed
        },
        initial: :compute
    end

    test "run_sync handles FanOutBranch directives via Task.async_stream" do
      agent = FanOutDSLWorkflow.new()

      assert {:ok, result} =
               FanOutDSLWorkflow.run_sync(agent, %{value: 1.0, amount: 2.0, message: "hello"})

      # Results should be merged and scoped under :compute
      assert result[:compute][:add][:result] == 3.0
      assert result[:compute][:echo][:echoed] == "hello"
    end
  end

  describe "custom terminal states" do
    defmodule CustomTerminalWorkflow do
      use Jido.Composer.Workflow,
        name: "custom_terminal",
        nodes: %{
          step_a: AddAction,
          step_b: MultiplyAction
        },
        transitions: %{
          {:step_a, :ok} => :step_b,
          {:step_b, :ok} => :complete,
          {:_, :error} => :failed
        },
        initial: :step_a,
        terminal_states: [:complete, :failed],
        success_states: [:complete]
    end

    test "custom terminal state :complete is classified as success" do
      agent = CustomTerminalWorkflow.new()

      assert {:ok, result} =
               CustomTerminalWorkflow.run_sync(agent, %{value: 1.0, amount: 2.0})

      assert is_map(result)
    end
  end

  describe "explicit success_states" do
    alias Jido.Composer.TestActions.FailAction

    defmodule ExplicitSuccessWorkflow do
      use Jido.Composer.Workflow,
        name: "explicit_success",
        nodes: %{
          step_a: AddAction,
          step_b: MultiplyAction
        },
        transitions: %{
          {:step_a, :ok} => :step_b,
          {:step_b, :ok} => :completed,
          {:_, :error} => :errored
        },
        initial: :step_a,
        terminal_states: [:completed, :errored, :cancelled],
        success_states: [:completed]
    end

    defmodule MultipleFailureWorkflow do
      use Jido.Composer.Workflow,
        name: "multiple_failure",
        nodes: %{
          step_a: FailAction
        },
        transitions: %{
          {:step_a, :ok} => :done,
          {:step_a, :error} => :errored,
          {:_, :error} => :cancelled
        },
        initial: :step_a,
        terminal_states: [:done, :errored, :cancelled],
        success_states: [:done]
    end

    test "explicit success_states: completed terminal is success" do
      agent = ExplicitSuccessWorkflow.new()
      assert {:ok, result} = ExplicitSuccessWorkflow.run_sync(agent, %{value: 1.0, amount: 2.0})
      assert is_map(result)
    end

    test "explicit success_states: non-success terminal is failure" do
      agent = MultipleFailureWorkflow.new()
      assert {:error, _reason} = MultipleFailureWorkflow.run_sync(agent, %{})
    end

    test "terminal state atom used as error_reason when no explicit error captured" do
      # Build a workflow that transitions to :cancelled (a failure terminal) without
      # going through a node that sets error_reason
      defmodule CancelledWorkflow do
        use Jido.Composer.Workflow,
          name: "cancelled_wf",
          nodes: %{
            step_a: AddAction
          },
          transitions: %{
            {:step_a, :ok} => :cancelled,
            {:_, :error} => :errored
          },
          initial: :step_a,
          terminal_states: [:done, :errored, :cancelled],
          success_states: [:done]
      end

      agent = CancelledWorkflow.new()
      assert {:error, :cancelled} = CancelledWorkflow.run_sync(agent, %{value: 1.0, amount: 2.0})
    end

    test "compile error when success_states not subset of terminal_states" do
      assert_raise CompileError, fn ->
        defmodule BadSuccessStatesWorkflow do
          use Jido.Composer.Workflow,
            name: "bad_success",
            nodes: %{step: AddAction},
            transitions: %{{:step, :ok} => :done, {:_, :error} => :failed},
            initial: :step,
            terminal_states: [:done, :failed],
            success_states: [:done, :nonexistent]
        end
      end
    end

    test "compile error when terminal_states provided without success_states" do
      assert_raise CompileError, ~r/terminal_states requires success_states/, fn ->
        defmodule TerminalOnlyWorkflow do
          use Jido.Composer.Workflow,
            name: "terminal_only",
            nodes: %{step: AddAction},
            transitions: %{{:step, :ok} => :complete, {:_, :error} => :failed},
            initial: :step,
            terminal_states: [:complete, :failed]
        end
      end
    end

    test "compile error when success_states provided without terminal_states" do
      assert_raise CompileError, ~r/success_states requires terminal_states/, fn ->
        defmodule SuccessOnlyWorkflow do
          use Jido.Composer.Workflow,
            name: "success_only",
            nodes: %{step: AddAction},
            transitions: %{{:step, :ok} => :done, {:_, :error} => :failed},
            initial: :step,
            success_states: [:done]
        end
      end
    end
  end

  describe "run_sync result serialization" do
    defmodule AmbientWorkflow do
      use Jido.Composer.Workflow,
        name: "ambient_workflow",
        nodes: %{
          step: AddAction
        },
        transitions: %{
          {:step, :ok} => :done,
          {:_, :error} => :failed
        },
        initial: :step,
        ambient: [:org_id, :region]
    end

    test "run_sync result does not contain the ambient tuple key" do
      agent = AmbientWorkflow.new()

      assert {:ok, result} =
               AmbientWorkflow.run_sync(agent, %{
                 value: 1.0,
                 amount: 2.0,
                 org_id: "acme",
                 region: "us-east"
               })

      # The result map must not contain the internal {Jido.Composer.Context, :ambient} tuple key
      refute Map.has_key?(result, Jido.Composer.Context.ambient_key()),
             "run_sync result should not expose the internal ambient tuple key"
    end

    test "run_sync result is Jason-encodable when ambient keys are present" do
      agent = AmbientWorkflow.new()

      assert {:ok, result} =
               AmbientWorkflow.run_sync(agent, %{
                 value: 1.0,
                 amount: 2.0,
                 org_id: "acme",
                 region: "us-east"
               })

      # If the tuple key leaks through, Jason.encode! will raise
      assert {:ok, _json} = Jason.encode(result)
    end
  end

  describe "suspension via run_sync" do
    defmodule SuspendWorkflow do
      use Jido.Composer.Workflow,
        name: "suspend_workflow",
        nodes: %{
          step_a: Jido.Composer.TestActions.SuspendAction
        },
        transitions: %{
          {:step_a, :ok} => :done,
          {:_, :error} => :failed
        },
        initial: :step_a
    end

    test "run_sync returns suspended error when action returns :suspend" do
      agent = SuspendWorkflow.new()

      assert {:error, {:suspended, suspension}} =
               SuspendWorkflow.run_sync(agent, %{checkpoint: "waiting"})

      assert %Jido.Composer.Suspension{} = suspension
    end
  end

  describe "compile-time validation" do
    test "rejects initial state not in nodes" do
      assert_raise CompileError, fn ->
        defmodule BadInitialWorkflow do
          use Jido.Composer.Workflow,
            name: "bad_initial",
            nodes: %{step: AddAction},
            transitions: %{{:step, :ok} => :done},
            initial: :nonexistent
        end
      end
    end

    test "rejects transition targets not in nodes or terminal states" do
      assert_raise CompileError, fn ->
        defmodule BadTransitionWorkflow do
          use Jido.Composer.Workflow,
            name: "bad_transition",
            nodes: %{step: AddAction},
            transitions: %{{:step, :ok} => :nonexistent},
            initial: :step
        end
      end
    end
  end
end
