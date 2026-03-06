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

  describe "build_nodes AgentNode opts passthrough" do
    test "agent tuple opts are passed directly to AgentNode.new without double-wrapping" do
      alias Jido.Composer.Node.AgentNode

      agent_opts = [mode: :sync]

      ctx = %{
        agent_module: TestWorkflowAgent,
        strategy_opts: [
          nodes: %{
            step: {:action, Jido.Composer.TestActions.AddAction},
            delegate: {:agent, Jido.Composer.TestAgents.EchoAgent, agent_opts}
          },
          transitions: %{
            {:step, :ok} => :delegate,
            {:delegate, :ok} => :done,
            {:_, :error} => :failed
          },
          initial: :step
        ]
      }

      agent = TestWorkflowAgent.new()
      {agent, _directives} = Strategy.init(agent, ctx)

      strat = StratState.get(agent)
      delegate_node = strat.machine.nodes[:delegate]

      # The node must be an AgentNode
      assert %AgentNode{} = delegate_node
      # mode: should be :sync from the opts, not lost inside a nested opts key
      assert delegate_node.mode == :sync
      # opts should be [] (no extra opts beyond mode), NOT [mode: :sync]
      # because mode is extracted by AgentNode.new and stored in the :mode field
      assert delegate_node.opts == []
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

  describe "FanOut directive-based dispatch" do
    alias Jido.Composer.Directive.FanOutBranch
    alias Jido.Composer.Node.{ActionNode, FanOutNode}

    defp init_fan_out_workflow(opts \\ []) do
      {:ok, add_node} = ActionNode.new(Jido.Composer.TestActions.AddAction)
      {:ok, echo_node} = ActionNode.new(Jido.Composer.TestActions.EchoAction)

      fan_out_opts = [
        name: "parallel",
        branches: [add: add_node, echo: echo_node]
      ]

      fan_out_opts =
        if mc = Keyword.get(opts, :max_concurrency) do
          Keyword.put(fan_out_opts, :max_concurrency, mc)
        else
          fan_out_opts
        end

      fan_out_opts =
        if oe = Keyword.get(opts, :on_error) do
          Keyword.put(fan_out_opts, :on_error, oe)
        else
          fan_out_opts
        end

      {:ok, fan_out} = FanOutNode.new(fan_out_opts)

      ctx = %{
        agent_module: TestWorkflowAgent,
        strategy_opts: [
          nodes: %{compute: fan_out},
          transitions: %{
            {:compute, :ok} => :done,
            {:compute, :error} => :failed,
            {:_, :error} => :failed
          },
          initial: :compute
        ]
      }

      agent = TestWorkflowAgent.new()
      {agent, _} = Strategy.init(agent, ctx)

      # Start workflow
      {agent, directives} =
        Strategy.cmd(
          agent,
          [
            %Jido.Instruction{
              action: :workflow_start,
              params: %{value: 1.0, amount: 2.0, message: "hi"}
            }
          ],
          ctx
        )

      {agent, directives, ctx}
    end

    test "dispatch FanOutNode emits FanOutBranch directives" do
      {_agent, directives, _ctx} = init_fan_out_workflow()

      assert length(directives) == 2
      assert Enum.all?(directives, &match?(%FanOutBranch{}, &1))

      branch_names = Enum.map(directives, & &1.branch_name) |> Enum.sort()
      assert branch_names == [:add, :echo]

      # Each branch has the same fan_out_id
      ids = Enum.map(directives, & &1.fan_out_id) |> Enum.uniq()
      assert length(ids) == 1
    end

    test "fan_out_branch_result tracks completion" do
      {agent, _directives, ctx} = init_fan_out_workflow()

      # Feed first branch result
      {agent, _directives} =
        Strategy.cmd(
          agent,
          [
            %Jido.Instruction{
              action: :fan_out_branch_result,
              params: %{branch_name: :add, result: {:ok, %{result: 3.0}}}
            }
          ],
          ctx
        )

      strat = StratState.get(agent)
      assert strat.pending_fan_out != nil
      assert strat.pending_fan_out.completed_results[:add] == %{result: 3.0}
    end

    test "fan_out completes when all branches done (merge + transition)" do
      {agent, _directives, ctx} = init_fan_out_workflow()

      # Feed both branch results
      {agent, _} =
        Strategy.cmd(
          agent,
          [
            %Jido.Instruction{
              action: :fan_out_branch_result,
              params: %{branch_name: :add, result: {:ok, %{result: 3.0}}}
            }
          ],
          ctx
        )

      {agent, directives} =
        Strategy.cmd(
          agent,
          [
            %Jido.Instruction{
              action: :fan_out_branch_result,
              params: %{branch_name: :echo, result: {:ok, %{echoed: "hi"}}}
            }
          ],
          ctx
        )

      # Should have transitioned to terminal state
      strat = StratState.get(agent)
      assert strat.machine.status == :done
      assert strat.pending_fan_out == nil
      assert directives == []

      # Results should be merged and scoped under :compute
      assert strat.machine.context.working[:compute][:add][:result] == 3.0
      assert strat.machine.context.working[:compute][:echo][:echoed] == "hi"
    end

    test "fail_fast cancels on error" do
      {:ok, add_node} = ActionNode.new(Jido.Composer.TestActions.AddAction)
      {:ok, fail_node} = ActionNode.new(Jido.Composer.TestActions.FailAction)

      {:ok, fan_out} =
        FanOutNode.new(
          name: "failing",
          branches: [add: add_node, fail: fail_node],
          on_error: :fail_fast
        )

      ctx = %{
        agent_module: TestWorkflowAgent,
        strategy_opts: [
          nodes: %{compute: fan_out},
          transitions: %{
            {:compute, :ok} => :done,
            {:compute, :error} => :failed,
            {:_, :error} => :failed
          },
          initial: :compute
        ]
      }

      agent = TestWorkflowAgent.new()
      {agent, _} = Strategy.init(agent, ctx)

      {agent, _directives} =
        Strategy.cmd(
          agent,
          [%Jido.Instruction{action: :workflow_start, params: %{value: 1.0, amount: 2.0}}],
          ctx
        )

      # Feed error result
      {agent, directives} =
        Strategy.cmd(
          agent,
          [
            %Jido.Instruction{
              action: :fan_out_branch_result,
              params: %{branch_name: :fail, result: {:error, "intentional failure"}}
            }
          ],
          ctx
        )

      strat = StratState.get(agent)
      assert strat.machine.status == :failed
      assert strat.pending_fan_out == nil

      # Directives may include StopChild for remaining pending branches
      assert is_list(directives)
    end

    test "collect_partial continues on error" do
      {agent, _directives, ctx} = init_fan_out_workflow(on_error: :collect_partial)

      # Feed error for one branch
      {agent, _} =
        Strategy.cmd(
          agent,
          [
            %Jido.Instruction{
              action: :fan_out_branch_result,
              params: %{branch_name: :add, result: {:error, "add failed"}}
            }
          ],
          ctx
        )

      strat = StratState.get(agent)
      # Still pending, not failed
      assert strat.pending_fan_out != nil
      assert strat.pending_fan_out.completed_results[:add] == {:error, "add failed"}

      # Feed success for second branch — should complete
      {agent, _} =
        Strategy.cmd(
          agent,
          [
            %Jido.Instruction{
              action: :fan_out_branch_result,
              params: %{branch_name: :echo, result: {:ok, %{echoed: "hi"}}}
            }
          ],
          ctx
        )

      strat = StratState.get(agent)
      assert strat.machine.status == :done
      assert strat.pending_fan_out == nil
    end

    test "max_concurrency limits dispatch" do
      {:ok, add_node1} = ActionNode.new(Jido.Composer.TestActions.AddAction)
      {:ok, add_node2} = ActionNode.new(Jido.Composer.TestActions.AddAction)
      {:ok, echo_node} = ActionNode.new(Jido.Composer.TestActions.EchoAction)

      {:ok, fan_out} =
        FanOutNode.new(
          name: "limited",
          branches: [a: add_node1, b: add_node2, c: echo_node],
          max_concurrency: 2
        )

      ctx = %{
        agent_module: TestWorkflowAgent,
        strategy_opts: [
          nodes: %{compute: fan_out},
          transitions: %{
            {:compute, :ok} => :done,
            {:_, :error} => :failed
          },
          initial: :compute
        ]
      }

      agent = TestWorkflowAgent.new()
      {agent, _} = Strategy.init(agent, ctx)

      {agent, directives} =
        Strategy.cmd(
          agent,
          [
            %Jido.Instruction{
              action: :workflow_start,
              params: %{value: 1.0, amount: 2.0, message: "hi"}
            }
          ],
          ctx
        )

      # Only 2 branches dispatched
      assert length(directives) == 2

      # 1 branch queued
      strat = StratState.get(agent)
      assert length(strat.pending_fan_out.queued_branches) == 1
    end

    test "queued branches dispatch as slots open" do
      {:ok, add_node1} = ActionNode.new(Jido.Composer.TestActions.AddAction)
      {:ok, add_node2} = ActionNode.new(Jido.Composer.TestActions.AddAction)
      {:ok, echo_node} = ActionNode.new(Jido.Composer.TestActions.EchoAction)

      {:ok, fan_out} =
        FanOutNode.new(
          name: "limited",
          branches: [a: add_node1, b: add_node2, c: echo_node],
          max_concurrency: 2
        )

      ctx = %{
        agent_module: TestWorkflowAgent,
        strategy_opts: [
          nodes: %{compute: fan_out},
          transitions: %{
            {:compute, :ok} => :done,
            {:_, :error} => :failed
          },
          initial: :compute
        ]
      }

      agent = TestWorkflowAgent.new()
      {agent, _} = Strategy.init(agent, ctx)

      {agent, _directives} =
        Strategy.cmd(
          agent,
          [
            %Jido.Instruction{
              action: :workflow_start,
              params: %{value: 1.0, amount: 2.0, message: "hi"}
            }
          ],
          ctx
        )

      # Complete first branch — queued branch should be dispatched
      {agent, new_directives} =
        Strategy.cmd(
          agent,
          [
            %Jido.Instruction{
              action: :fan_out_branch_result,
              params: %{branch_name: :a, result: {:ok, %{result: 3.0}}}
            }
          ],
          ctx
        )

      # Should have dispatched the queued branch
      assert length(new_directives) == 1
      assert [%FanOutBranch{branch_name: :c}] = new_directives

      strat = StratState.get(agent)
      assert strat.pending_fan_out.queued_branches == []
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

  describe "generalized suspension" do
    alias Jido.Composer.Directive.Suspend, as: SuspendDirective
    alias Jido.Composer.Suspension
    alias Jido.Composer.Node.HumanNode

    defp init_suspend_workflow do
      ctx = %{
        agent_module: TestWorkflowAgent,
        strategy_opts: [
          nodes: %{
            prepare: {:action, Jido.Composer.TestActions.AddAction},
            awaiting: {:action, Jido.Composer.TestActions.SuspendAction},
            finalize: {:action, Jido.Composer.TestActions.MultiplyAction}
          },
          transitions: %{
            {:prepare, :ok} => :awaiting,
            {:awaiting, :ok} => :finalize,
            {:awaiting, :timeout} => :failed,
            {:finalize, :ok} => :done,
            {:_, :error} => :failed
          },
          initial: :prepare
        ]
      }

      agent = TestWorkflowAgent.new()
      {agent, _directives} = Strategy.init(agent, ctx)
      {agent, ctx}
    end

    defp advance_to_suspend(agent, ctx) do
      # Start workflow
      {agent, _} =
        Strategy.cmd(
          agent,
          [%Jido.Instruction{action: :workflow_start, params: %{value: 1.0, amount: 2.0}}],
          ctx
        )

      # Simulate successful result from prepare node -> transitions to :awaiting
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

      # Now the strategy dispatches awaiting node (SuspendAction).
      # Simulate the SuspendAction result with outcome: :suspend
      Strategy.cmd(
        agent,
        [
          %Jido.Instruction{
            action: :workflow_node_result,
            params: %{
              status: :ok,
              result: %{checkpoint: "paused"},
              outcome: :suspend,
              instruction: %Jido.Instruction{
                action: Jido.Composer.TestActions.SuspendAction,
                params: %{}
              },
              effects: [],
              meta: %{}
            }
          }
        ],
        ctx
      )
    end

    test "node returning :suspend creates Suspension and emits Suspend directive" do
      {agent, ctx} = init_suspend_workflow()
      {agent, directives} = advance_to_suspend(agent, ctx)

      # Should emit a single SuspendDirective
      assert [%SuspendDirective{suspension: %Suspension{} = suspension}] = directives

      # Suspension should have reason :custom (no __suspension__ in result)
      assert suspension.reason == :custom
      assert is_binary(suspension.id)
      assert suspension.metadata == %{node_state: :awaiting}

      # Strategy status should be :waiting
      assert StratState.status(agent) == :waiting

      # Machine should still be at :awaiting (no transition happened)
      strat = StratState.get(agent)
      assert strat.machine.status == :awaiting
      assert strat.pending_suspension == suspension

      # Result data should be merged into context under current state
      assert strat.machine.context.working[:awaiting] == %{checkpoint: "paused"}
    end

    test "suspend_resume with matching id transitions machine" do
      {agent, ctx} = init_suspend_workflow()
      {agent, _directives} = advance_to_suspend(agent, ctx)

      strat = StratState.get(agent)
      suspension_id = strat.pending_suspension.id

      # Send suspend_resume with the correct suspension id
      {agent, directives} =
        Strategy.cmd(
          agent,
          [
            %Jido.Instruction{
              action: :suspend_resume,
              params: %{
                suspension_id: suspension_id,
                outcome: :ok,
                data: %{resumed_by: "test"}
              }
            }
          ],
          ctx
        )

      # Should dispatch the next node (finalize / MultiplyAction)
      assert [%Directive.RunInstruction{} = run] = directives
      assert run.instruction.action == Jido.Composer.TestActions.MultiplyAction

      # Status should be :running again
      assert StratState.status(agent) == :running

      # Machine should have transitioned to :finalize
      strat = StratState.get(agent)
      assert strat.machine.status == :finalize
      assert strat.pending_suspension == nil

      # Resume data should be merged into context
      assert strat.machine.context.working[:resumed_by] == "test"
    end

    test "suspend_resume with mismatched id errors" do
      {agent, ctx} = init_suspend_workflow()
      {agent, _directives} = advance_to_suspend(agent, ctx)

      strat = StratState.get(agent)
      real_id = strat.pending_suspension.id

      # Send suspend_resume with a wrong suspension id
      {agent, directives} =
        Strategy.cmd(
          agent,
          [
            %Jido.Instruction{
              action: :suspend_resume,
              params: %{
                suspension_id: "wrong-id-12345",
                outcome: :ok
              }
            }
          ],
          ctx
        )

      # Should return an error directive with mismatch message
      assert [%Directive.Error{error: %RuntimeError{message: message}}] = directives
      assert message =~ "Suspension ID mismatch"
      assert message =~ inspect(real_id)
      assert message =~ "wrong-id-12345"

      # Status should remain :waiting
      assert StratState.status(agent) == :waiting

      # Pending suspension should still be there
      strat = StratState.get(agent)
      assert strat.pending_suspension != nil
    end

    test "suspend_timeout fires timeout outcome" do
      {agent, ctx} = init_suspend_workflow()
      {agent, _directives} = advance_to_suspend(agent, ctx)

      strat = StratState.get(agent)
      suspension_id = strat.pending_suspension.id

      # Send suspend_timeout with the correct suspension id
      {agent, directives} =
        Strategy.cmd(
          agent,
          [
            %Jido.Instruction{
              action: :suspend_timeout,
              params: %{suspension_id: suspension_id}
            }
          ],
          ctx
        )

      # The timeout_outcome defaults to :timeout, which should transition
      # {:awaiting, :timeout} => :failed
      assert directives == []

      strat = StratState.get(agent)
      assert strat.machine.status == :failed
      assert StratState.status(agent) == :failure
      assert strat.pending_suspension == nil
    end

    test "suspend_resume with no pending suspension errors" do
      {agent, ctx} = init_suspend_workflow()

      # Start but do NOT suspend - just start the workflow
      {agent, _} =
        Strategy.cmd(
          agent,
          [%Jido.Instruction{action: :workflow_start, params: %{value: 1.0, amount: 2.0}}],
          ctx
        )

      # Try to resume when there's no pending suspension
      {_agent, directives} =
        Strategy.cmd(
          agent,
          [
            %Jido.Instruction{
              action: :suspend_resume,
              params: %{suspension_id: "some-id", outcome: :ok}
            }
          ],
          ctx
        )

      assert [%Directive.Error{error: %RuntimeError{message: "No pending suspension"}}] =
               directives
    end

    test "suspend with explicit Suspension struct in result" do
      {agent, ctx} = init_suspend_workflow()

      # Start workflow and advance to awaiting
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

      # Simulate a result that includes an explicit __suspension__ struct
      {:ok, custom_suspension} =
        Suspension.new(
          reason: :rate_limit,
          metadata: %{retry_after_ms: 5000},
          timeout: 30_000,
          timeout_outcome: :timeout
        )

      {agent, directives} =
        Strategy.cmd(
          agent,
          [
            %Jido.Instruction{
              action: :workflow_node_result,
              params: %{
                status: :ok,
                result: %{processed: false, __suspension__: custom_suspension},
                outcome: :suspend,
                instruction: %Jido.Instruction{
                  action: Jido.Composer.TestActions.SuspendAction,
                  params: %{}
                },
                effects: [],
                meta: %{}
              }
            }
          ],
          ctx
        )

      assert [%SuspendDirective{suspension: %Suspension{} = suspension}] = directives
      # Should use the explicit suspension, not create a :custom one
      assert suspension.reason == :rate_limit
      assert suspension.metadata == %{retry_after_ms: 5000}
      assert suspension.timeout == 30_000

      strat = StratState.get(agent)
      assert strat.pending_suspension.reason == :rate_limit
    end

    test "HumanNode backward compat through generalized suspension" do
      # Build a workflow with a HumanNode at the :review state
      {:ok, human_node} =
        HumanNode.new(
          name: "review_gate",
          description: "Review gate",
          prompt: "Please review",
          allowed_responses: [:approved, :rejected],
          timeout: 60_000,
          timeout_outcome: :timeout
        )

      ctx = %{
        agent_module: TestWorkflowAgent,
        strategy_opts: [
          nodes: %{
            prepare: {:action, Jido.Composer.TestActions.AddAction},
            review: human_node,
            finalize: {:action, Jido.Composer.TestActions.MultiplyAction}
          },
          transitions: %{
            {:prepare, :ok} => :review,
            {:review, :approved} => :finalize,
            {:review, :rejected} => :failed,
            {:review, :timeout} => :failed,
            {:finalize, :ok} => :done,
            {:_, :error} => :failed
          },
          initial: :prepare
        ]
      }

      agent = TestWorkflowAgent.new()
      {agent, _directives} = Strategy.init(agent, ctx)

      # Start and advance to review
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

      # HumanNode dispatches via dispatch_human_node, which emits SuspendForHuman
      # The dispatch_current_node matches %HumanNode{} and calls dispatch_human_node
      # This should create a Suspension with reason: :human_input
      strat = StratState.get(agent)
      assert strat.status == :waiting
      assert %Suspension{reason: :human_input} = strat.pending_suspension
      assert strat.pending_suspension.approval_request != nil

      suspension_id = strat.pending_suspension.id

      # Resume using the generalized suspend_resume with the suspension id
      {agent, directives} =
        Strategy.cmd(
          agent,
          [
            %Jido.Instruction{
              action: :suspend_resume,
              params: %{
                suspension_id: suspension_id,
                response_data: %{
                  request_id: strat.pending_suspension.approval_request.id,
                  decision: :approved,
                  respondent: "reviewer@test.com"
                }
              }
            }
          ],
          ctx
        )

      # Should dispatch finalize node
      assert [%Directive.RunInstruction{} = run] = directives
      assert run.instruction.action == Jido.Composer.TestActions.MultiplyAction

      # Status should be :running, machine at :finalize
      assert StratState.status(agent) == :running
      strat = StratState.get(agent)
      assert strat.machine.status == :finalize
      assert strat.pending_suspension == nil

      # HITL response data should be in context
      assert strat.machine.context.working[:hitl_response][:decision] == :approved
    end
  end

  describe "FanOut + suspension interaction" do
    test "collect_partial preserves error results in completed_results map" do
      alias Jido.Composer.Node.{ActionNode, FanOutNode}
      alias Jido.Composer.Directive.FanOutBranch

      {:ok, ok_node} = ActionNode.new(Jido.Composer.TestActions.AddAction)
      {:ok, fail_node} = ActionNode.new(Jido.Composer.TestActions.FailAction)
      {:ok, echo_node} = ActionNode.new(Jido.Composer.TestActions.EchoAction)

      {:ok, fan_out} =
        FanOutNode.new(
          name: "three_branch",
          branches: [ok: ok_node, fail: fail_node, echo: echo_node],
          on_error: :collect_partial
        )

      ctx = %{
        agent_module: TestWorkflowAgent,
        strategy_opts: [
          nodes: %{compute: fan_out},
          transitions: %{
            {:compute, :ok} => :done,
            {:compute, :error} => :failed,
            {:_, :error} => :failed
          },
          initial: :compute
        ]
      }

      agent = TestWorkflowAgent.new()
      {agent, _} = Strategy.init(agent, ctx)

      {agent, _directives} =
        Strategy.cmd(
          agent,
          [
            %Jido.Instruction{
              action: :workflow_start,
              params: %{value: 1.0, amount: 2.0, message: "hi"}
            }
          ],
          ctx
        )

      # Feed: first branch OK
      {agent, _} =
        Strategy.cmd(
          agent,
          [
            %Jido.Instruction{
              action: :fan_out_branch_result,
              params: %{branch_name: :ok, result: {:ok, %{result: 3.0}}}
            }
          ],
          ctx
        )

      # Feed: second branch ERROR
      {agent, _} =
        Strategy.cmd(
          agent,
          [
            %Jido.Instruction{
              action: :fan_out_branch_result,
              params: %{branch_name: :fail, result: {:error, "intentional failure"}}
            }
          ],
          ctx
        )

      # Still pending — waiting for third branch
      strat = StratState.get(agent)
      assert strat.pending_fan_out != nil
      assert strat.pending_fan_out.completed_results[:ok] == %{result: 3.0}
      assert strat.pending_fan_out.completed_results[:fail] == {:error, "intentional failure"}

      # Feed: third branch OK — should complete
      {agent, _} =
        Strategy.cmd(
          agent,
          [
            %Jido.Instruction{
              action: :fan_out_branch_result,
              params: %{branch_name: :echo, result: {:ok, %{echoed: "hi"}}}
            }
          ],
          ctx
        )

      strat = StratState.get(agent)
      assert strat.machine.status == :done
      assert strat.pending_fan_out == nil

      # Error branch result preserved in merged context
      ctx_working = strat.machine.context.working
      assert ctx_working[:compute][:ok][:result] == 3.0
      assert ctx_working[:compute][:echo][:echoed] == "hi"
      # Error branches are stored as {:error, reason} tuples in collect_partial mode
      assert ctx_working[:compute][:fail] == {:error, "intentional failure"}
    end
  end

  describe "checkpoint readiness" do
    test "prepare_for_checkpoint strips closures from live strategy state" do
      alias Jido.Composer.Checkpoint

      {agent, ctx} = init_agent()

      # Start workflow
      {agent, _} =
        Strategy.cmd(
          agent,
          [%Jido.Instruction{action: :workflow_start, params: %{value: 1.0, amount: 2.0}}],
          ctx
        )

      strat = StratState.get(agent)
      checkpoint = Checkpoint.prepare_for_checkpoint(strat)

      # Verify no closures remain
      for {_key, value} <- checkpoint do
        refute is_function(value),
               "Checkpoint should not contain closures, found function in strategy state"
      end

      # Verify core state is preserved
      assert checkpoint.machine.status == :extract
      assert checkpoint.status == :running
      assert checkpoint.module == Strategy
    end
  end
end
