defmodule Jido.Composer.Integration.WorkflowFanOutSuspensionTest do
  use ExUnit.Case, async: true

  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.Composer.Directive.FanOutBranch
  alias Jido.Composer.Directive.Suspend, as: SuspendDirective
  alias Jido.Composer.Node.ActionNode
  alias Jido.Composer.Node.FanOutNode
  alias Jido.Composer.Suspension
  alias Jido.Composer.Workflow.Strategy

  alias Jido.Composer.TestActions.{
    AddAction,
    EchoAction,
    RateLimitAction
  }

  # -- Workflow definitions --

  defmodule SuspendingFanOutWorkflow do
    {:ok, rate_node} = ActionNode.new(RateLimitAction)
    {:ok, echo_node} = ActionNode.new(EchoAction)

    {:ok, fan_out} =
      FanOutNode.new(
        name: "suspend_parallel",
        branches: [rate: rate_node, echo: echo_node]
      )

    use Jido.Composer.Workflow,
      name: "susfan_out",
      description: "FanOut with a branch that may suspend",
      nodes: %{compute: fan_out},
      transitions: %{
        {:compute, :ok} => :done,
        {:compute, :error} => :failed,
        {:_, :error} => :failed
      },
      initial: :compute
  end

  # -- Helpers --

  defp execute_fan_out_branch(%FanOutBranch{child_node: child_node, params: params}) do
    case child_node.__struct__.run(child_node, params, []) do
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

  describe "FanOut with suspending branch" do
    test "run, suspend, resume, complete" do
      agent = SuspendingFanOutWorkflow.new()

      # tokens=0 makes RateLimitAction suspend
      {agent, directives} =
        SuspendingFanOutWorkflow.run(agent, %{tokens: 0, message: "hello"})

      assert length(directives) == 2
      assert Enum.all?(directives, &match?(%FanOutBranch{}, &1))

      # Execute all branches — one will suspend
      {agent, directives} =
        feed_branch_results(SuspendingFanOutWorkflow, agent, directives)

      # Should have a suspend directive since the rate branch suspended
      strat = StratState.get(agent)

      cond do
        # If suspend directives were emitted, we're in waiting state
        Enum.any?(directives, &match?(%SuspendDirective{}, &1)) ->
          assert strat.status == :waiting
          assert strat.fan_out != nil
          assert map_size(strat.fan_out.suspended_branches) == 1

          # Get the suspension id
          [{_branch, %{suspension: suspension}}] =
            Enum.to_list(strat.fan_out.suspended_branches)

          # Resume the suspended branch
          {agent, _} =
            SuspendingFanOutWorkflow.cmd(
              agent,
              {:suspend_resume,
               %{
                 suspension_id: suspension.id,
                 outcome: :ok,
                 data: %{processed: true, tokens_remaining: 5}
               }}
            )

          strat = StratState.get(agent)
          assert strat.machine.status == :done
          assert strat.fan_out == nil

        # Otherwise both completed normally (shouldn't happen with tokens=0)
        true ->
          flunk("Expected at least one suspend directive")
      end
    end
  end

  describe "backpressure with suspension" do
    test "max_concurrency 1, first suspends, others dispatch after" do
      {:ok, rate_node} = ActionNode.new(RateLimitAction)
      {:ok, add_node} = ActionNode.new(AddAction)
      {:ok, echo_node} = ActionNode.new(EchoAction)

      {:ok, fan_out} =
        FanOutNode.new(
          name: "backpressure_test",
          branches: [rate: rate_node, add: add_node, echo: echo_node],
          max_concurrency: 1
        )

      ctx = %{
        agent_module: SuspendingFanOutWorkflow,
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

      agent = SuspendingFanOutWorkflow.new()
      {agent, _} = Strategy.init(agent, ctx)

      {agent, directives} =
        Strategy.cmd(
          agent,
          [
            %Jido.Instruction{
              action: :workflow_start,
              params: %{tokens: 0, value: 1.0, amount: 2.0, message: "test"}
            }
          ],
          ctx
        )

      # Only 1 branch dispatched (max_concurrency: 1)
      assert length(directives) == 1
      [first_branch] = directives
      assert %FanOutBranch{} = first_branch

      strat = StratState.get(agent)
      assert length(strat.fan_out.queued_branches) == 2

      # Execute first branch — it suspends, which frees the slot
      result = execute_fan_out_branch(first_branch)

      {agent, new_directives} =
        Strategy.cmd(
          agent,
          [
            %Jido.Instruction{
              action: :fan_out_branch_result,
              params: %{branch_name: first_branch.branch_name, result: result}
            }
          ],
          ctx
        )

      # Slot freed — next queued branch should be dispatched
      assert length(new_directives) == 1
      [second_branch] = new_directives
      assert %FanOutBranch{} = second_branch

      # Execute second branch
      result2 = execute_fan_out_branch(second_branch)

      {agent, new_directives2} =
        Strategy.cmd(
          agent,
          [
            %Jido.Instruction{
              action: :fan_out_branch_result,
              params: %{branch_name: second_branch.branch_name, result: result2}
            }
          ],
          ctx
        )

      # Third branch dispatched
      assert length(new_directives2) == 1
      [third_branch] = new_directives2

      result3 = execute_fan_out_branch(third_branch)

      {agent, directives} =
        Strategy.cmd(
          agent,
          [
            %Jido.Instruction{
              action: :fan_out_branch_result,
              params: %{branch_name: third_branch.branch_name, result: result3}
            }
          ],
          ctx
        )

      # Now we should have suspend directives for the first branch
      assert Enum.any?(directives, &match?(%SuspendDirective{}, &1))

      strat = StratState.get(agent)
      assert strat.status == :waiting

      # Get suspension id and resume
      [{_branch_name, %{suspension: sus}}] =
        Enum.to_list(strat.fan_out.suspended_branches)

      {agent, _} =
        Strategy.cmd(
          agent,
          [
            %Jido.Instruction{
              action: :suspend_resume,
              params: %{
                suspension_id: sus.id,
                outcome: :ok,
                data: %{processed: true, tokens_remaining: 5}
              }
            }
          ],
          ctx
        )

      strat = StratState.get(agent)
      assert strat.machine.status == :done
      assert strat.fan_out == nil
    end
  end

  describe "snapshot during fan-out suspension" do
    test "snapshot shows suspended branch details" do
      agent = SuspendingFanOutWorkflow.new()
      {agent, directives} = SuspendingFanOutWorkflow.run(agent, %{tokens: 0, message: "hello"})

      {agent, _directives} =
        feed_branch_results(SuspendingFanOutWorkflow, agent, directives)

      snapshot = Strategy.snapshot(agent, %{})

      assert snapshot.status == :waiting
      assert snapshot.details.reason == :fan_out_suspended
      assert is_list(snapshot.details.suspended_branches)
    end
  end
end
