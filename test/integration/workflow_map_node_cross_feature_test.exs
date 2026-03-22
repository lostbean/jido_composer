defmodule Jido.Composer.Integration.WorkflowMapNodeCrossFeatureTest do
  use ExUnit.Case, async: true

  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.Composer.Checkpoint
  alias Jido.Composer.Directive.FanOutBranch
  alias Jido.Composer.Directive.Suspend, as: SuspendDirective

  alias Jido.Composer.Node.MapNode
  alias Jido.Composer.Suspension
  alias Jido.Composer.Workflow.Strategy

  # -- Test Actions --

  defmodule SuspendingElementAction do
    @moduledoc false
    use Jido.Action,
      name: "suspending_element",
      description: "Suspends when tokens is 0",
      schema: [
        tokens: [type: :integer, required: false, doc: "Tokens remaining"]
      ]

    def run(params, _context) do
      tokens = Map.get(params, :tokens, 0)

      if tokens > 0 do
        {:ok, %{processed: true, tokens_remaining: tokens - 1}}
      else
        {:ok, suspension} =
          Jido.Composer.Suspension.new(
            reason: :rate_limit,
            metadata: %{retry_after_ms: 5000}
          )

        {:ok, %{processed: false, __suspension__: suspension}, :suspend}
      end
    end
  end

  defmodule DoubleValueAction do
    @moduledoc false
    use Jido.Action,
      name: "double_value",
      description: "Doubles a numeric value",
      schema: [
        value: [type: :float, required: true, doc: "Value to double"]
      ]

    def run(%{value: value}, _context) do
      {:ok, %{doubled: value * 2}}
    end
  end

  defmodule MaybeFailAction do
    @moduledoc false
    use Jido.Action,
      name: "maybe_fail",
      description: "Fails if should_fail is true",
      schema: [
        value: [type: :float, required: false, doc: "Value"],
        should_fail: [type: :boolean, required: false, doc: "Whether to fail"]
      ]

    def run(params, _context) do
      if Map.get(params, :should_fail, false) do
        {:error, "element failed"}
      else
        {:ok, %{value: Map.get(params, :value, 0)}}
      end
    end
  end

  # -- Workflow definitions --

  defmodule SuspendingMapWorkflow do
    {:ok, map_node} =
      MapNode.new(
        name: :compute,
        over: :items,
        action: SuspendingElementAction
      )

    use Jido.Composer.Workflow,
      name: "suspending_map",
      description: "MapNode with suspending elements",
      nodes: %{compute: map_node},
      transitions: %{
        {:compute, :ok} => :done,
        {:compute, :error} => :failed,
        {:_, :error} => :failed
      },
      initial: :compute
  end

  defmodule BackpressureMapWorkflow do
    {:ok, map_node} =
      MapNode.new(
        name: :compute,
        over: :items,
        action: DoubleValueAction,
        max_concurrency: 1
      )

    use Jido.Composer.Workflow,
      name: "backpressure_map",
      description: "MapNode with max_concurrency 1",
      nodes: %{compute: map_node},
      transitions: %{
        {:compute, :ok} => :done,
        {:compute, :error} => :failed,
        {:_, :error} => :failed
      },
      initial: :compute
  end

  defmodule CollectPartialMapWorkflow do
    {:ok, map_node} =
      MapNode.new(
        name: :compute,
        over: :items,
        action: MaybeFailAction,
        on_error: :collect_partial
      )

    use Jido.Composer.Workflow,
      name: "collect_partial_map",
      description: "MapNode with collect_partial error mode",
      nodes: %{compute: map_node},
      transitions: %{
        {:compute, :ok} => :done,
        {:compute, :error} => :failed,
        {:_, :error} => :failed
      },
      initial: :compute
  end

  # -- Helpers --

  defp execute_fan_out_branch(%FanOutBranch{instruction: %Jido.Instruction{} = instr}) do
    case Jido.Exec.run(instr.action, instr.params) do
      {:ok, result} ->
        if Map.has_key?(result, :__suspension__) do
          suspension = result.__suspension__
          clean = Map.drop(result, [:__suspension__, :__approval_request__])
          {:suspend, suspension, clean}
        else
          {:ok, result}
        end

      {:ok, result, :suspend} ->
        if Map.has_key?(result, :__suspension__) do
          suspension = result.__suspension__
          clean = Map.drop(result, [:__suspension__, :__approval_request__])
          {:suspend, suspension, clean}
        else
          {:ok, suspension} = Suspension.new(reason: :custom, metadata: %{})
          {:suspend, suspension, result}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp feed_branch_results(agent_module, agent, fan_out_directives) do
    Enum.reduce(fan_out_directives, {agent, []}, fn %FanOutBranch{} = branch, {acc, _dirs} ->
      result = execute_fan_out_branch(branch)

      agent_module.cmd(
        acc,
        {:fan_out_branch_result, %{branch_name: branch.branch_name, result: result}}
      )
    end)
  end

  # -- Tests --

  describe "MapNode element suspension" do
    test "element suspends, resume completes with ordered_list merge" do
      agent = SuspendingMapWorkflow.new()

      # tokens=5 succeeds, tokens=0 suspends, tokens=3 succeeds
      {agent, directives} =
        SuspendingMapWorkflow.run(agent, %{
          items: [%{tokens: 5}, %{tokens: 0}, %{tokens: 3}]
        })

      assert length(directives) == 3
      assert Enum.all?(directives, &match?(%FanOutBranch{}, &1))

      # Execute all branches — item_1 will suspend
      {agent, directives} =
        feed_branch_results(SuspendingMapWorkflow, agent, directives)

      strat = StratState.get(agent)

      assert Enum.any?(directives, &match?(%SuspendDirective{}, &1)),
             "Expected at least one suspend directive"

      assert strat.status == :waiting
      assert strat.fan_out != nil
      assert map_size(strat.fan_out.suspended_branches) == 1

      # Get the suspension id
      [{_branch, %{suspension: suspension}}] =
        Enum.to_list(strat.fan_out.suspended_branches)

      # Resume the suspended branch
      {agent, _} =
        SuspendingMapWorkflow.cmd(
          agent,
          {:suspend_resume,
           %{
             suspension_id: suspension.id,
             outcome: :ok,
             data: %{processed: true}
           }}
        )

      strat = StratState.get(agent)
      assert strat.machine.status == :done
      assert strat.fan_out == nil

      # Verify ordered_list merge produced results with all 3 elements
      ctx = strat.machine.context.working
      results = ctx[:compute][:results]
      assert is_list(results)
      assert length(results) == 3
    end

    test "all elements suspend, resume each, merge preserves order" do
      agent = SuspendingMapWorkflow.new()

      {agent, directives} =
        SuspendingMapWorkflow.run(agent, %{
          items: [%{tokens: 0}, %{tokens: 0}]
        })

      assert length(directives) == 2

      # Execute all branches — both will suspend
      {agent, _directives} =
        feed_branch_results(SuspendingMapWorkflow, agent, directives)

      strat = StratState.get(agent)
      assert strat.status == :waiting
      assert map_size(strat.fan_out.suspended_branches) == 2

      # Resume item_0 first
      suspended_list = Enum.to_list(strat.fan_out.suspended_branches)

      {_, %{suspension: sus_0}} =
        Enum.find(suspended_list, fn {name, _} -> name == :item_0 end)

      {_, %{suspension: sus_1}} =
        Enum.find(suspended_list, fn {name, _} -> name == :item_1 end)

      {agent, _} =
        SuspendingMapWorkflow.cmd(
          agent,
          {:suspend_resume,
           %{
             suspension_id: sus_0.id,
             outcome: :ok,
             data: %{processed: true, order: 0}
           }}
        )

      # Still waiting — item_1 is suspended
      strat = StratState.get(agent)
      assert strat.status == :waiting

      {agent, _} =
        SuspendingMapWorkflow.cmd(
          agent,
          {:suspend_resume,
           %{
             suspension_id: sus_1.id,
             outcome: :ok,
             data: %{processed: true, order: 1}
           }}
        )

      strat = StratState.get(agent)
      assert strat.machine.status == :done
      assert strat.fan_out == nil

      ctx = strat.machine.context.working
      results = ctx[:compute][:results]
      assert is_list(results)
      assert length(results) == 2

      # Verify order: item_0 result comes before item_1
      [r0, r1] = results
      assert r0[:order] == 0
      assert r1[:order] == 1
    end
  end

  describe "MapNode backpressure" do
    test "max_concurrency 1 dispatches items sequentially through strategy" do
      ctx = %{
        agent_module: BackpressureMapWorkflow,
        strategy_opts: [
          nodes: %{
            compute:
              elem(
                MapNode.new(
                  name: :compute,
                  over: :items,
                  action: DoubleValueAction,
                  max_concurrency: 1
                ),
                1
              )
          },
          transitions: %{
            {:compute, :ok} => :done,
            {:compute, :error} => :failed,
            {:_, :error} => :failed
          },
          initial: :compute
        ]
      }

      agent = BackpressureMapWorkflow.new()
      {agent, _} = Strategy.init(agent, ctx)

      {agent, directives} =
        Strategy.cmd(
          agent,
          [
            %Jido.Instruction{
              action: :workflow_start,
              params: %{items: [%{value: 1.0}, %{value: 2.0}, %{value: 3.0}]}
            }
          ],
          ctx
        )

      # Only 1 branch dispatched (max_concurrency: 1)
      assert length(directives) == 1
      [first_branch] = directives
      assert %FanOutBranch{} = first_branch
      assert first_branch.branch_name == :item_0

      strat = StratState.get(agent)
      assert length(strat.fan_out.queued_branches) == 2

      # Feed item_0 result
      result0 = execute_fan_out_branch(first_branch)

      {agent, directives1} =
        Strategy.cmd(
          agent,
          [
            %Jido.Instruction{
              action: :fan_out_branch_result,
              params: %{branch_name: :item_0, result: result0}
            }
          ],
          ctx
        )

      # Next branch dispatched, 1 queued
      assert length(directives1) == 1
      [second_branch] = directives1
      assert %FanOutBranch{} = second_branch
      assert second_branch.branch_name == :item_1

      strat = StratState.get(agent)
      assert length(strat.fan_out.queued_branches) == 1

      # Feed item_1 result
      result1 = execute_fan_out_branch(second_branch)

      {agent, directives2} =
        Strategy.cmd(
          agent,
          [
            %Jido.Instruction{
              action: :fan_out_branch_result,
              params: %{branch_name: :item_1, result: result1}
            }
          ],
          ctx
        )

      # Last branch dispatched, 0 queued
      assert length(directives2) == 1
      [third_branch] = directives2
      assert %FanOutBranch{} = third_branch
      assert third_branch.branch_name == :item_2

      # Feed item_2 result
      result2 = execute_fan_out_branch(third_branch)

      {agent, _directives3} =
        Strategy.cmd(
          agent,
          [
            %Jido.Instruction{
              action: :fan_out_branch_result,
              params: %{branch_name: :item_2, result: result2}
            }
          ],
          ctx
        )

      # Workflow done
      strat = StratState.get(agent)
      assert strat.machine.status == :done
      assert strat.fan_out == nil

      # Verify all 3 results in order
      ctx_w = strat.machine.context.working
      results = ctx_w[:compute][:results]
      assert results == [%{doubled: 2.0}, %{doubled: 4.0}, %{doubled: 6.0}]
    end
  end

  describe "MapNode checkpoint serialization" do
    test "FanOut.State with ordered_list merge survives checkpoint round-trip" do
      {:ok, map_node} =
        MapNode.new(
          name: :compute,
          over: :items,
          action: DoubleValueAction
        )

      fan_out_state = %{
        id: "map-123",
        node: map_node,
        pending_branches: MapSet.new([:item_2]),
        completed_results: %{item_0: %{doubled: 2.0}, item_1: %{doubled: 4.0}},
        suspended_branches: %{},
        queued_branches: [],
        merge: :ordered_list,
        on_error: :fail_fast
      }

      strat = %{
        module: Jido.Composer.Workflow.Strategy,
        status: :running,
        machine: %{status: :compute, context: %{}},
        fan_out: fan_out_state,
        pending_suspension: nil
      }

      cleaned = Checkpoint.prepare_for_checkpoint(strat)
      binary = :erlang.term_to_binary(cleaned, [:compressed])
      restored = :erlang.binary_to_term(binary)

      assert restored.fan_out.merge == :ordered_list

      assert restored.fan_out.completed_results == %{
               item_0: %{doubled: 2.0},
               item_1: %{doubled: 4.0}
             }

      assert MapSet.member?(restored.fan_out.pending_branches, :item_2)
    end

    test "MapNode struct is fully serializable" do
      {:ok, node} =
        MapNode.new(
          name: :compute,
          over: :items,
          action: DoubleValueAction,
          max_concurrency: 2,
          timeout: 60_000,
          on_error: :collect_partial
        )

      binary = :erlang.term_to_binary(node, [:compressed])
      restored = :erlang.binary_to_term(binary)

      assert %MapNode{} = restored
      assert restored.name == :compute
      assert restored.over == :items
      assert restored.action == DoubleValueAction
      assert restored.merge == :ordered_list
      assert restored.timeout == 60_000
      assert restored.on_error == :collect_partial
      assert restored.max_concurrency == 2
    end
  end

  describe "MapNode snapshot" do
    test "snapshot shows suspended MapNode branch details" do
      agent = SuspendingMapWorkflow.new()

      {agent, directives} =
        SuspendingMapWorkflow.run(agent, %{
          items: [%{tokens: 5}, %{tokens: 0}]
        })

      {agent, _directives} =
        feed_branch_results(SuspendingMapWorkflow, agent, directives)

      snapshot = Strategy.snapshot(agent, %{})

      assert snapshot.status == :waiting
      assert snapshot.details.reason == :fan_out_suspended
      assert is_list(snapshot.details.suspended_branches)
      assert length(snapshot.details.suspended_branches) == 1

      [branch_info] = snapshot.details.suspended_branches
      assert branch_info.branch == :item_1
      assert branch_info.reason == :rate_limit
    end
  end

  describe "MapNode collect_partial error mode" do
    test "collect_partial gathers errors alongside successes" do
      agent = CollectPartialMapWorkflow.new()

      {agent, directives} =
        CollectPartialMapWorkflow.run(agent, %{
          items: [
            %{value: 1.0, should_fail: false},
            %{value: 2.0, should_fail: true},
            %{value: 3.0, should_fail: false}
          ]
        })

      assert length(directives) == 3
      assert Enum.all?(directives, &match?(%FanOutBranch{}, &1))

      # Feed all branch results
      {agent, _directives} =
        feed_branch_results(CollectPartialMapWorkflow, agent, directives)

      strat = StratState.get(agent)

      # Workflow should complete (not fail) because collect_partial gathers errors
      assert strat.machine.status == :done
      assert strat.fan_out == nil

      ctx = strat.machine.context.working
      results = ctx[:compute][:results]
      assert is_list(results)
      assert length(results) == 3

      # item_0: success, item_1: error tuple, item_2: success
      assert %{value: 1.0} = Enum.at(results, 0)
      assert {:error, _} = Enum.at(results, 1)
      assert %{value: 3.0} = Enum.at(results, 2)
    end
  end
end
