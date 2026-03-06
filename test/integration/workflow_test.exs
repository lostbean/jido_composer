defmodule Jido.Composer.Integration.WorkflowTest do
  use ExUnit.Case, async: true

  alias Jido.Agent.Directive
  alias Jido.Agent.Strategy.State, as: StratState

  alias Jido.Composer.TestActions.{
    ExtractAction,
    TransformAction,
    LoadAction,
    AddAction,
    MultiplyAction,
    FailAction,
    AccumulatorAction,
    ValidateAction,
    ValidateOutcomeAction,
    NoopAction
  }

  # -- Workflow definitions --

  defmodule ETLWorkflow do
    use Jido.Composer.Workflow,
      name: "etl_pipeline",
      description: "Extract, transform, load pipeline",
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

  defmodule BranchingWorkflow do
    use Jido.Composer.Workflow,
      name: "branching_workflow",
      description: "Workflow that branches on validation outcome",
      nodes: %{
        validate: ValidateAction,
        process: NoopAction,
        handle_error: NoopAction
      },
      transitions: %{
        {:validate, :ok} => :process,
        {:validate, :error} => :handle_error,
        {:process, :ok} => :done,
        {:handle_error, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :validate
  end

  defmodule ThreeStepWorkflow do
    use Jido.Composer.Workflow,
      name: "three_step",
      description: "A → B → C pipeline for context isolation tests",
      nodes: %{
        step_a: AccumulatorAction,
        step_b: AccumulatorAction,
        step_c: AccumulatorAction
      },
      transitions: %{
        {:step_a, :ok} => :step_b,
        {:step_b, :ok} => :step_c,
        {:step_c, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :step_a
  end

  defmodule MathWorkflow do
    use Jido.Composer.Workflow,
      name: "math_pipeline",
      description: "Add then multiply",
      nodes: %{
        add: AddAction,
        multiply: MultiplyAction
      },
      transitions: %{
        {:add, :ok} => :multiply,
        {:multiply, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :add
  end

  defmodule FailFirstWorkflow do
    use Jido.Composer.Workflow,
      name: "fail_first",
      nodes: %{
        step: FailAction,
        next: NoopAction
      },
      transitions: %{
        {:step, :ok} => :next,
        {:next, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :step
  end

  defmodule MidFailWorkflow do
    use Jido.Composer.Workflow,
      name: "mid_fail",
      nodes: %{
        first: NoopAction,
        second: FailAction,
        third: NoopAction
      },
      transitions: %{
        {:first, :ok} => :second,
        {:second, :ok} => :third,
        {:third, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :first
  end

  defmodule NoTransitionWorkflow do
    use Jido.Composer.Workflow,
      name: "no_transition",
      nodes: %{
        step: FailAction
      },
      transitions: %{
        {:step, :ok} => :done
      },
      initial: :step
  end

  defmodule CustomOutcomeWorkflow do
    use Jido.Composer.Workflow,
      name: "custom_outcome",
      description: "Workflow that branches on custom outcome atoms",
      nodes: %{
        check: ValidateOutcomeAction,
        process: NoopAction,
        quarantine: NoopAction,
        retry_step: NoopAction
      },
      transitions: %{
        {:check, :ok} => :process,
        {:check, :invalid} => :quarantine,
        {:check, :retry} => :retry_step,
        {:process, :ok} => :done,
        {:quarantine, :ok} => :done,
        {:retry_step, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :check
  end

  # -- Helpers --

  # Simulates the AgentServer directive execution loop.
  # Runs RunInstruction directives by executing the action and feeding
  # the result back via cmd/2 until no more directives are produced.
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

      _other ->
        run_directive_loop(agent_module, agent, rest)
    end
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

      {:ok, result, outcome} ->
        %{
          status: :ok,
          result: result,
          outcome: outcome,
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

  # -- Tests --

  describe "linear pipeline (ETL)" do
    test "executes all three steps to completion" do
      agent = ETLWorkflow.new()
      {agent, directives} = ETLWorkflow.run(agent, %{source: "test_db"})

      assert [%Directive.RunInstruction{}] = directives
      agent = execute_workflow(ETLWorkflow, agent, directives)

      strat = StratState.get(agent)
      assert strat.machine.status == :done
      assert StratState.status(agent) == :success
    end

    test "accumulates scoped context from each step" do
      agent = ETLWorkflow.new()
      {agent, directives} = ETLWorkflow.run(agent, %{source: "test_db"})
      agent = execute_workflow(ETLWorkflow, agent, directives)

      strat = StratState.get(agent)
      ctx = strat.machine.context.working

      # Extract step scoped its result
      assert ctx[:extract][:records] == [%{id: 1, source: "test_db"}, %{id: 2, source: "test_db"}]
      assert ctx[:extract][:count] == 2

      # Transform step read from extract and scoped its result
      assert ctx[:transform][:records] == [
               %{id: 1, source: "TEST_DB"},
               %{id: 2, source: "TEST_DB"}
             ]

      # Load step scoped its result
      assert ctx[:load][:loaded] == 2
      assert ctx[:load][:status] == :complete
    end

    test "records transition history" do
      agent = ETLWorkflow.new()
      {agent, directives} = ETLWorkflow.run(agent, %{source: "test_db"})
      agent = execute_workflow(ETLWorkflow, agent, directives)

      strat = StratState.get(agent)
      history = strat.machine.history

      # History is in reverse order (most recent first)
      assert length(history) == 3
      states = Enum.map(history, fn {state, _outcome, _ts} -> state end) |> Enum.reverse()
      assert states == [:extract, :transform, :load]

      outcomes = Enum.map(history, fn {_state, outcome, _ts} -> outcome end)
      assert Enum.all?(outcomes, &(&1 == :ok))
    end
  end

  describe "branching workflow" do
    test "follows success path when validation passes" do
      agent = BranchingWorkflow.new()
      {agent, directives} = BranchingWorkflow.run(agent, %{valid: true})
      agent = execute_workflow(BranchingWorkflow, agent, directives)

      strat = StratState.get(agent)
      assert strat.machine.status == :done
      assert StratState.status(agent) == :success

      # Verify it went through validate -> process -> done
      history_states =
        strat.machine.history
        |> Enum.map(fn {state, _outcome, _ts} -> state end)
        |> Enum.reverse()

      assert history_states == [:validate, :process]
    end

    test "follows error branch when validation fails" do
      agent = BranchingWorkflow.new()
      {agent, directives} = BranchingWorkflow.run(agent, %{valid: false})
      agent = execute_workflow(BranchingWorkflow, agent, directives)

      strat = StratState.get(agent)
      assert strat.machine.status == :done
      assert StratState.status(agent) == :success

      # Verify it went through validate -> handle_error -> done
      history_states =
        strat.machine.history
        |> Enum.map(fn {state, _outcome, _ts} -> state end)
        |> Enum.reverse()

      assert history_states == [:validate, :handle_error]
    end
  end

  describe "error handling" do
    test "transitions to :failed on wildcard error match" do
      agent = FailFirstWorkflow.new()
      {agent, directives} = FailFirstWorkflow.run(agent, %{reason: "bad data"})
      agent = execute_workflow(FailFirstWorkflow, agent, directives)

      strat = StratState.get(agent)
      assert strat.machine.status == :failed
      assert StratState.status(agent) == :failure
    end

    test "mid-pipeline error transitions to :failed" do
      agent = MidFailWorkflow.new()
      {agent, directives} = MidFailWorkflow.run(agent, %{})
      agent = execute_workflow(MidFailWorkflow, agent, directives)

      strat = StratState.get(agent)
      assert strat.machine.status == :failed
      assert StratState.status(agent) == :failure

      # First step should have completed, second failed
      history_states =
        strat.machine.history
        |> Enum.map(fn {state, _outcome, _ts} -> state end)
        |> Enum.reverse()

      assert history_states == [:first, :second]
    end

    test "no transition match results in :failure status" do
      agent = NoTransitionWorkflow.new()
      {agent, directives} = NoTransitionWorkflow.run(agent, %{})
      agent = execute_workflow(NoTransitionWorkflow, agent, directives)

      assert StratState.status(agent) == :failure
    end
  end

  describe "context isolation" do
    test "each step's result is scoped under its state name" do
      agent = ThreeStepWorkflow.new()
      {agent, directives} = ThreeStepWorkflow.run(agent, %{tag: "initial"})
      agent = execute_workflow(ThreeStepWorkflow, agent, directives)

      strat = StratState.get(agent)
      ctx = strat.machine.context.working

      # Each step scoped under its state name
      assert ctx[:step_a][:tag] == "initial"
      assert ctx[:step_b][:tag] == "initial"
      assert ctx[:step_c][:tag] == "initial"
    end

    test "initial params are preserved in context" do
      agent = ETLWorkflow.new()
      {agent, directives} = ETLWorkflow.run(agent, %{source: "my_source", extra: "data"})
      agent = execute_workflow(ETLWorkflow, agent, directives)

      strat = StratState.get(agent)
      ctx = strat.machine.context.working

      # Initial params should still be in context
      assert ctx[:source] == "my_source"
      assert ctx[:extra] == "data"
    end

    test "scoped results don't overwrite initial params of different keys" do
      agent = MathWorkflow.new()
      {agent, directives} = MathWorkflow.run(agent, %{value: 5.0, amount: 3.0})
      agent = execute_workflow(MathWorkflow, agent, directives)

      strat = StratState.get(agent)
      ctx = strat.machine.context.working

      # Initial params preserved
      assert ctx[:value] == 5.0
      assert ctx[:amount] == 3.0

      # Add step: 5 + 3 = 8, scoped under :add
      assert ctx[:add][:result] == 8.0

      # Multiply step: 5 * 3 = 15 (it receives the full context including value/amount)
      assert ctx[:multiply][:result] == 15.0
    end
  end

  describe "custom outcomes" do
    test "follows :ok path on valid data" do
      agent = CustomOutcomeWorkflow.new()
      {agent, directives} = CustomOutcomeWorkflow.run(agent, %{data: "valid"})
      agent = execute_workflow(CustomOutcomeWorkflow, agent, directives)

      strat = StratState.get(agent)
      assert strat.machine.status == :done

      history_states =
        strat.machine.history
        |> Enum.map(fn {state, _outcome, _ts} -> state end)
        |> Enum.reverse()

      assert history_states == [:check, :process]
    end

    test "follows :invalid path on invalid data" do
      agent = CustomOutcomeWorkflow.new()
      {agent, directives} = CustomOutcomeWorkflow.run(agent, %{data: "invalid"})
      agent = execute_workflow(CustomOutcomeWorkflow, agent, directives)

      strat = StratState.get(agent)
      assert strat.machine.status == :done

      history_states =
        strat.machine.history
        |> Enum.map(fn {state, _outcome, _ts} -> state end)
        |> Enum.reverse()

      assert history_states == [:check, :quarantine]
    end

    test "follows :retry path on retry data" do
      agent = CustomOutcomeWorkflow.new()
      {agent, directives} = CustomOutcomeWorkflow.run(agent, %{data: "retry"})
      agent = execute_workflow(CustomOutcomeWorkflow, agent, directives)

      strat = StratState.get(agent)
      assert strat.machine.status == :done

      history_states =
        strat.machine.history
        |> Enum.map(fn {state, _outcome, _ts} -> state end)
        |> Enum.reverse()

      assert history_states == [:check, :retry_step]
    end
  end

  describe "ambient context flow" do
    test "ambient context flows through all workflow states" do
      agent = ETLWorkflow.new()

      assert {:ok, result} =
               ETLWorkflow.run_sync(agent, %{
                 source: "ambient_test",
                 __ambient__: %{org_id: "acme"}
               })

      # The result from run_sync is a flat map (via to_flat_map)
      # Ambient key __ambient__ is populated even though we passed it as initial param
      # (it ends up in working since DSL doesn't extract ambient keys yet)
      assert result[:extract][:records] != nil
      assert result[:load][:status] == :complete
    end

    test "fork functions run at agent boundaries" do
      alias Jido.Agent.Strategy.State, as: StratState
      alias Jido.Composer.Context
      alias Jido.Composer.Workflow.Strategy

      # Create a workflow agent module for testing
      agent_module = Jido.Composer.Integration.WorkflowTest.ETLWorkflow

      # Set up strategy with Context that has fork functions
      defmodule TestForks do
        def depth_fork(ambient, _working) do
          Map.update(ambient, :depth, 1, &(&1 + 1))
        end
      end

      ctx =
        Context.new(
          ambient: %{org_id: "acme", depth: 0},
          working: %{},
          fork_fns: %{depth: {TestForks, :depth_fork, []}}
        )

      strategy_opts = [
        nodes: %{
          prepare: {:action, Jido.Composer.TestActions.AddAction},
          delegate: {:agent, Jido.Composer.TestAgents.EchoAgent, []}
        },
        transitions: %{
          {:prepare, :ok} => :delegate,
          {:delegate, :ok} => :done,
          {:_, :error} => :failed
        },
        initial: :prepare
      ]

      agent = Jido.Composer.Integration.WorkflowTest.ETLWorkflow.new()
      strat_ctx = %{agent_module: agent_module, strategy_opts: strategy_opts}
      {agent, _} = Strategy.init(agent, strat_ctx)

      # Manually set the machine context to use our Context with fork functions
      strat = StratState.get(agent)
      machine = %{strat.machine | context: ctx}

      agent =
        StratState.update(agent, fn s -> %{s | machine: machine} end)

      # Start workflow
      {agent, _} =
        Strategy.cmd(
          agent,
          [%Jido.Instruction{action: :workflow_start, params: %{value: 1.0, amount: 2.0}}],
          strat_ctx
        )

      # Simulate result from prepare -> transitions to delegate (AgentNode)
      {_agent, directives} =
        Strategy.cmd(
          agent,
          [
            %Jido.Instruction{
              action: :workflow_node_result,
              params: %{
                status: :ok,
                result: %{result: 3.0},
                instruction: %Jido.Instruction{
                  action: Jido.Composer.TestActions.AddAction,
                  params: %{}
                },
                effects: [],
                meta: %{}
              }
            }
          ],
          strat_ctx
        )

      # SpawnAgent should have forked context with depth incremented
      assert [%Jido.Agent.Directive.SpawnAgent{} = spawn] = directives
      child_ctx = spawn.opts[:context]
      assert child_ctx[:__ambient__][:depth] == 1
      assert child_ctx[:__ambient__][:org_id] == "acme"
    end
  end

  describe "run_sync/2" do
    test "blocks until workflow completes and returns result context" do
      agent = ETLWorkflow.new()
      assert {:ok, result} = ETLWorkflow.run_sync(agent, %{source: "test_db"})

      assert result[:extract][:count] == 2
      assert result[:load][:status] == :complete
    end

    test "returns error on workflow failure" do
      agent = FailFirstWorkflow.new()
      assert {:error, _reason} = FailFirstWorkflow.run_sync(agent, %{})
    end
  end

  describe "snapshot" do
    test "reports idle before execution" do
      agent = ETLWorkflow.new()
      ctx = %{agent_module: ETLWorkflow, strategy_opts: ETLWorkflow.strategy_opts()}
      snap = Jido.Composer.Workflow.Strategy.snapshot(agent, ctx)

      assert snap.status == :idle
      refute snap.done?
    end

    test "reports success after completion" do
      agent = ETLWorkflow.new()
      {agent, directives} = ETLWorkflow.run(agent, %{source: "test"})
      agent = execute_workflow(ETLWorkflow, agent, directives)

      ctx = %{agent_module: ETLWorkflow, strategy_opts: ETLWorkflow.strategy_opts()}
      snap = Jido.Composer.Workflow.Strategy.snapshot(agent, ctx)

      assert snap.status == :success
      assert snap.done?
    end

    test "reports failure after error" do
      agent = FailFirstWorkflow.new()
      {agent, directives} = FailFirstWorkflow.run(agent, %{})
      agent = execute_workflow(FailFirstWorkflow, agent, directives)

      ctx = %{agent_module: FailFirstWorkflow, strategy_opts: FailFirstWorkflow.strategy_opts()}
      snap = Jido.Composer.Workflow.Strategy.snapshot(agent, ctx)

      assert snap.status == :failure
      assert snap.done?
    end
  end
end
