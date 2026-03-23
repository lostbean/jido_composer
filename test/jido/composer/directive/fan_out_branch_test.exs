defmodule Jido.Composer.Directive.FanOutBranchTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.Directive.FanOutBranch
  alias Jido.Composer.Node.ActionNode
  alias Jido.Composer.Node.AgentNode
  alias Jido.Composer.Node.FanOutNode
  alias Jido.Composer.Node.HumanNode
  alias Jido.Composer.TestActions.AddAction

  describe "struct — new child_node + params shape" do
    test "creates FanOutBranch with ActionNode child_node" do
      {:ok, action_node} = ActionNode.new(AddAction)

      branch = %FanOutBranch{
        fan_out_id: "abc123",
        branch_name: :validate,
        child_node: action_node,
        params: %{value: 1.0, amount: 2.0},
        result_action: :fan_out_branch_result
      }

      assert branch.fan_out_id == "abc123"
      assert branch.branch_name == :validate
      assert %ActionNode{action_module: AddAction} = branch.child_node
      assert branch.params == %{value: 1.0, amount: 2.0}
    end

    test "creates FanOutBranch with AgentNode child_node" do
      agent_node = %AgentNode{
        agent_module: Jido.Composer.TestAgents.TestWorkflowAgent,
        opts: [context: %{source: "test"}]
      }

      branch = %FanOutBranch{
        fan_out_id: "abc123",
        branch_name: :analyze,
        child_node: agent_node,
        params: %{source: "test"},
        result_action: :fan_out_branch_result
      }

      assert branch.fan_out_id == "abc123"
      assert branch.branch_name == :analyze
      assert %AgentNode{} = branch.child_node
      assert branch.params == %{source: "test"}
    end

    test "enforce_keys requires fan_out_id, branch_name, and child_node" do
      assert_raise ArgumentError, fn ->
        struct!(FanOutBranch, %{fan_out_id: "abc", branch_name: :test})
      end
    end

    test "old instruction field does not exist" do
      {:ok, action_node} = ActionNode.new(AddAction)
      branch = %FanOutBranch{fan_out_id: "a", branch_name: :b, child_node: action_node}
      refute Map.has_key?(branch, :instruction)
    end

    test "old spawn_agent field does not exist" do
      {:ok, action_node} = ActionNode.new(AddAction)
      branch = %FanOutBranch{fan_out_id: "a", branch_name: :b, child_node: action_node}
      refute Map.has_key?(branch, :spawn_agent)
    end

    test "params defaults to nil" do
      {:ok, action_node} = ActionNode.new(AddAction)

      branch = %FanOutBranch{
        fan_out_id: "abc123",
        branch_name: :test,
        child_node: action_node
      }

      assert branch.params == nil
    end

    test "timeout defaults to nil" do
      {:ok, action_node} = ActionNode.new(AddAction)

      branch = %FanOutBranch{
        fan_out_id: "abc123",
        branch_name: :test,
        child_node: action_node
      }

      assert branch.timeout == nil
    end
  end

  describe "serialization round-trip" do
    test "FanOutBranch with ActionNode child survives term_to_binary/binary_to_term" do
      {:ok, action_node} = ActionNode.new(AddAction)

      branch = %FanOutBranch{
        fan_out_id: "ser123",
        branch_name: :action_branch,
        child_node: action_node,
        params: %{value: 42},
        result_action: :fan_out_branch_result,
        timeout: 5_000
      }

      binary = :erlang.term_to_binary(branch)
      restored = :erlang.binary_to_term(binary)
      assert restored == branch
    end

    test "FanOutBranch with AgentNode child survives round-trip" do
      agent_node = %AgentNode{
        agent_module: Jido.Composer.TestAgents.TestWorkflowAgent,
        opts: [context: %{x: 1}]
      }

      branch = %FanOutBranch{
        fan_out_id: "ser456",
        branch_name: :agent_branch,
        child_node: agent_node,
        params: %{x: 1}
      }

      binary = :erlang.term_to_binary(branch)
      restored = :erlang.binary_to_term(binary)
      assert restored == branch
    end

    test "FanOutBranch with FanOutNode child survives round-trip" do
      {:ok, inner_add} = ActionNode.new(AddAction)

      {:ok, fan_out_node} =
        FanOutNode.new(name: "inner", branches: [add: inner_add])

      branch = %FanOutBranch{
        fan_out_id: "ser789",
        branch_name: :nested_fan_out,
        child_node: fan_out_node,
        params: %{value: 1.0, amount: 2.0}
      }

      binary = :erlang.term_to_binary(branch)
      restored = :erlang.binary_to_term(binary)
      assert restored == branch
    end

    test "FanOutBranch with HumanNode child survives round-trip" do
      {:ok, human_node} =
        HumanNode.new(
          name: "approve",
          description: "Approve item",
          prompt: "Do you approve?"
        )

      branch = %FanOutBranch{
        fan_out_id: "ser_human",
        branch_name: :human_branch,
        child_node: human_node,
        params: %{item: "test"}
      }

      binary = :erlang.term_to_binary(branch)
      restored = :erlang.binary_to_term(binary)
      assert restored == branch
    end
  end
end
