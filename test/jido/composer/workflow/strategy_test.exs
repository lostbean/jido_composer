defmodule Jido.Composer.Workflow.StrategyTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.Workflow.Strategy
  alias Jido.Composer.Workflow.Machine
  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.Agent.Directive

  # A minimal agent module for testing
  defmodule TestWorkflowAgent do
    use Jido.Agent,
      name: "test_workflow",
      description: "Test agent for workflow strategy tests",
      schema: []
  end

  defp strategy_context do
    %{
      agent_module: TestWorkflowAgent,
      strategy_opts: [
        nodes: %{
          extract: {:action, Jido.Composer.TestActions.AddAction},
          transform: {:action, Jido.Composer.TestActions.MultiplyAction}
        },
        transitions: %{
          {:extract, :ok} => :transform,
          {:transform, :ok} => :done,
          {:_, :error} => :failed
        },
        initial: :extract
      ]
    }
  end

  defp init_agent do
    agent = TestWorkflowAgent.new()
    ctx = strategy_context()
    {agent, _directives} = Strategy.init(agent, ctx)
    {agent, ctx}
  end

  describe "init/2" do
    test "initializes machine in strategy state" do
      {agent, _ctx} = init_agent()
      strat_state = StratState.get(agent)
      assert %Machine{} = strat_state.machine
      assert strat_state.machine.status == :extract
    end

    test "sets strategy module reference" do
      {agent, _ctx} = init_agent()
      strat_state = StratState.get(agent)
      assert strat_state.module == Strategy
    end

    test "sets status to :idle" do
      {agent, _ctx} = init_agent()
      assert StratState.status(agent) == :idle
    end
  end

  describe "cmd/3 - workflow_start" do
    test "dispatches first node as RunInstruction" do
      {agent, ctx} = init_agent()

      instructions = [
        %Jido.Instruction{action: :workflow_start, params: %{value: 1.0, amount: 2.0}}
      ]

      {_agent, directives} = Strategy.cmd(agent, instructions, ctx)

      assert [%Directive.RunInstruction{} = run] = directives
      assert run.result_action == :workflow_node_result
      assert run.instruction.action == Jido.Composer.TestActions.AddAction
    end

    test "sets status to :running" do
      {agent, ctx} = init_agent()

      instructions = [
        %Jido.Instruction{action: :workflow_start, params: %{value: 1.0, amount: 2.0}}
      ]

      {agent, _directives} = Strategy.cmd(agent, instructions, ctx)
      assert StratState.status(agent) == :running
    end

    test "merges initial params into machine context" do
      {agent, ctx} = init_agent()

      instructions = [
        %Jido.Instruction{action: :workflow_start, params: %{value: 1.0, amount: 2.0}}
      ]

      {agent, _directives} = Strategy.cmd(agent, instructions, ctx)
      strat = StratState.get(agent)
      assert strat.machine.context[:value] == 1.0
    end
  end

  describe "cmd/3 - workflow_node_result (success)" do
    test "transitions to next state and dispatches next node" do
      {agent, ctx} = init_agent()

      # Start workflow
      {agent, _} =
        Strategy.cmd(
          agent,
          [%Jido.Instruction{action: :workflow_start, params: %{value: 1.0, amount: 2.0}}],
          ctx
        )

      # Simulate successful result from extract node
      result_params = %{
        status: :ok,
        result: %{result: 3.0},
        instruction: %Jido.Instruction{action: Jido.Composer.TestActions.AddAction, params: %{}},
        effects: [],
        meta: %{}
      }

      {agent, directives} =
        Strategy.cmd(
          agent,
          [%Jido.Instruction{action: :workflow_node_result, params: result_params}],
          ctx
        )

      # Should dispatch the transform node
      assert [%Directive.RunInstruction{} = run] = directives
      assert run.instruction.action == Jido.Composer.TestActions.MultiplyAction

      # Machine should have transitioned to :transform
      strat = StratState.get(agent)
      assert strat.machine.status == :transform
    end

    test "scopes result under state name in context" do
      {agent, ctx} = init_agent()

      {agent, _} =
        Strategy.cmd(
          agent,
          [%Jido.Instruction{action: :workflow_start, params: %{value: 1.0, amount: 2.0}}],
          ctx
        )

      result_params = %{
        status: :ok,
        result: %{result: 3.0},
        instruction: %Jido.Instruction{action: Jido.Composer.TestActions.AddAction, params: %{}},
        effects: [],
        meta: %{}
      }

      {agent, _} =
        Strategy.cmd(
          agent,
          [%Jido.Instruction{action: :workflow_node_result, params: result_params}],
          ctx
        )

      strat = StratState.get(agent)
      assert strat.machine.context[:extract] == %{result: 3.0}
    end
  end

  describe "cmd/3 - terminal state" do
    test "returns no directives when reaching terminal state" do
      {agent, ctx} = init_agent()

      # Start
      {agent, _} =
        Strategy.cmd(
          agent,
          [%Jido.Instruction{action: :workflow_start, params: %{value: 1.0, amount: 2.0}}],
          ctx
        )

      # Extract result -> transitions to :transform
      {agent, _} =
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
          ctx
        )

      # Transform result -> transitions to :done (terminal)
      {agent, directives} =
        Strategy.cmd(
          agent,
          [
            %Jido.Instruction{
              action: :workflow_node_result,
              params: %{
                status: :ok,
                result: %{result: 6.0},
                instruction: %Jido.Instruction{
                  action: Jido.Composer.TestActions.MultiplyAction,
                  params: %{}
                },
                effects: [],
                meta: %{}
              }
            }
          ],
          ctx
        )

      assert directives == []
      assert StratState.status(agent) == :success
      strat = StratState.get(agent)
      assert strat.machine.status == :done
    end
  end

  describe "cmd/3 - error handling" do
    test "transitions to :failed on error outcome" do
      {agent, ctx} = init_agent()

      {agent, _} =
        Strategy.cmd(
          agent,
          [%Jido.Instruction{action: :workflow_start, params: %{value: 1.0, amount: 2.0}}],
          ctx
        )

      result_params = %{
        status: :error,
        reason: "something broke",
        instruction: %Jido.Instruction{action: Jido.Composer.TestActions.AddAction, params: %{}},
        effects: [],
        meta: %{}
      }

      {agent, _directives} =
        Strategy.cmd(
          agent,
          [%Jido.Instruction{action: :workflow_node_result, params: result_params}],
          ctx
        )

      strat = StratState.get(agent)
      assert strat.machine.status == :failed
      assert StratState.status(agent) == :failure
    end
  end

  describe "signal_routes/1" do
    test "declares workflow signal routes" do
      routes = Strategy.signal_routes(%{})

      route_types = Enum.map(routes, fn {type, _target} -> type end)
      assert "composer.workflow.start" in route_types
    end
  end

  describe "snapshot/2" do
    test "returns idle snapshot before start" do
      {agent, ctx} = init_agent()
      snap = Strategy.snapshot(agent, ctx)
      assert snap.status == :idle
      refute snap.done?
    end

    test "returns success snapshot after completion" do
      {agent, ctx} = init_agent()

      {agent, _} =
        Strategy.cmd(
          agent,
          [%Jido.Instruction{action: :workflow_start, params: %{value: 1.0, amount: 2.0}}],
          ctx
        )

      {agent, _} =
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
          ctx
        )

      {agent, _} =
        Strategy.cmd(
          agent,
          [
            %Jido.Instruction{
              action: :workflow_node_result,
              params: %{
                status: :ok,
                result: %{result: 6.0},
                instruction: %Jido.Instruction{
                  action: Jido.Composer.TestActions.MultiplyAction,
                  params: %{}
                },
                effects: [],
                meta: %{}
              }
            }
          ],
          ctx
        )

      snap = Strategy.snapshot(agent, ctx)
      assert snap.status == :success
      assert snap.done?
    end
  end
end
