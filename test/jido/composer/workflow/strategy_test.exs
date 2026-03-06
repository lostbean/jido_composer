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
      assert strat.machine.context.working[:value] == 1.0
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
      assert strat.machine.context.working[:extract] == %{result: 3.0}
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

  describe "cmd/3 - AgentNode dispatch" do
    defp init_agent_node_workflow do
      ctx = %{
        agent_module: TestWorkflowAgent,
        strategy_opts: [
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
      }

      agent = TestWorkflowAgent.new()
      {agent, _directives} = Strategy.init(agent, ctx)
      {agent, ctx}
    end

    test "SpawnAgent directive includes machine context for child" do
      {agent, ctx} = init_agent_node_workflow()

      # Start workflow
      {agent, _} =
        Strategy.cmd(
          agent,
          [%Jido.Instruction{action: :workflow_start, params: %{value: 1.0, amount: 2.0}}],
          ctx
        )

      # Simulate successful result from prepare node -> transitions to :delegate (AgentNode)
      result_params = %{
        status: :ok,
        result: %{result: 3.0},
        instruction: %Jido.Instruction{action: Jido.Composer.TestActions.AddAction, params: %{}},
        effects: [],
        meta: %{}
      }

      {_agent, directives} =
        Strategy.cmd(
          agent,
          [%Jido.Instruction{action: :workflow_node_result, params: result_params}],
          ctx
        )

      assert [%Directive.SpawnAgent{} = spawn] = directives
      assert spawn.agent == Jido.Composer.TestAgents.EchoAgent
      # Context should be included in opts so the child receives it
      assert spawn.opts[:context] != nil
      assert spawn.opts[:context][:value] == 1.0
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

  describe "Context integration" do
    test "dispatch passes flat map with __ambient__ to ActionNode" do
      {agent, ctx} = init_agent()

      instructions = [
        %Jido.Instruction{action: :workflow_start, params: %{value: 1.0, amount: 2.0}}
      ]

      {_agent, directives} = Strategy.cmd(agent, instructions, ctx)

      assert [%Directive.RunInstruction{instruction: instr}] = directives
      # ActionNode should receive flat map with __ambient__ key
      assert Map.has_key?(instr.params, :__ambient__)
      assert instr.params[:value] == 1.0
    end

    test "dispatch forks context for AgentNode SpawnAgent" do
      # Use the agent_node_workflow setup
      ctx = %{
        agent_module: TestWorkflowAgent,
        strategy_opts: [
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
      }

      agent = TestWorkflowAgent.new()
      {agent, _directives} = Strategy.init(agent, ctx)

      # Start workflow
      {agent, _} =
        Strategy.cmd(
          agent,
          [%Jido.Instruction{action: :workflow_start, params: %{value: 1.0, amount: 2.0}}],
          ctx
        )

      # Simulate successful result from prepare node -> transitions to :delegate (AgentNode)
      result_params = %{
        status: :ok,
        result: %{result: 3.0},
        instruction: %Jido.Instruction{action: Jido.Composer.TestActions.AddAction, params: %{}},
        effects: [],
        meta: %{}
      }

      {_agent, directives} =
        Strategy.cmd(
          agent,
          [%Jido.Instruction{action: :workflow_node_result, params: result_params}],
          ctx
        )

      assert [%Directive.SpawnAgent{} = spawn] = directives
      # Child receives a flat map context with __ambient__
      assert Map.has_key?(spawn.opts[:context], :__ambient__)
    end
  end

  describe "persistence readiness" do
    test "strategy state is serializable via :erlang.term_to_binary" do
      {agent, ctx} = init_agent()

      # Start workflow
      instructions = [
        %Jido.Instruction{action: :workflow_start, params: %{value: 1.0, amount: 2.0}}
      ]

      {agent, _directives} = Strategy.cmd(agent, instructions, ctx)

      # Strategy state must be serializable (no PIDs, refs, etc.)
      strat_state = StratState.get(agent)
      binary = :erlang.term_to_binary(strat_state)
      restored = :erlang.binary_to_term(binary)

      assert restored.machine.status == strat_state.machine.status
      assert restored.machine.context == strat_state.machine.context
      assert restored.status == strat_state.status
    end
  end
end
