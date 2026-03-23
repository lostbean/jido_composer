defmodule Jido.Composer.Node.FanOutNodeTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.Node.FanOutNode
  alias Jido.Composer.Node.ActionNode
  alias Jido.Composer.NodeIO
  alias Jido.Composer.TestActions.{AddAction, EchoAction, FailAction}

  describe "new/1" do
    test "creates a FanOutNode with required fields" do
      {:ok, add_node} = ActionNode.new(AddAction)
      {:ok, echo_node} = ActionNode.new(EchoAction)

      assert {:ok, node} =
               FanOutNode.new(
                 name: "parallel_step",
                 branches: [add: add_node, echo: echo_node]
               )

      assert %FanOutNode{} = node
      assert node.name == "parallel_step"
      assert length(node.branches) == 2
    end

    test "defaults merge to :deep_merge" do
      {:ok, add_node} = ActionNode.new(AddAction)
      {:ok, node} = FanOutNode.new(name: "test", branches: [add: add_node])
      assert node.merge == :deep_merge
    end

    test "defaults timeout to 30_000" do
      {:ok, add_node} = ActionNode.new(AddAction)
      {:ok, node} = FanOutNode.new(name: "test", branches: [add: add_node])
      assert node.timeout == 30_000
    end

    test "defaults on_error to :fail_fast" do
      {:ok, add_node} = ActionNode.new(AddAction)
      {:ok, node} = FanOutNode.new(name: "test", branches: [add: add_node])
      assert node.on_error == :fail_fast
    end

    test "accepts custom timeout" do
      {:ok, add_node} = ActionNode.new(AddAction)
      {:ok, node} = FanOutNode.new(name: "test", branches: [add: add_node], timeout: 60_000)
      assert node.timeout == 60_000
    end

    test "accepts infinity timeout" do
      {:ok, add_node} = ActionNode.new(AddAction)
      {:ok, node} = FanOutNode.new(name: "test", branches: [add: add_node], timeout: :infinity)
      assert node.timeout == :infinity
    end

    test "accepts custom merge function" do
      {:ok, add_node} = ActionNode.new(AddAction)
      merge_fn = fn results -> Enum.into(results, %{}) end
      {:ok, node} = FanOutNode.new(name: "test", branches: [add: add_node], merge: merge_fn)
      assert is_function(node.merge, 1)
    end

    test "accepts on_error: :collect_partial" do
      {:ok, add_node} = ActionNode.new(AddAction)

      {:ok, node} =
        FanOutNode.new(name: "test", branches: [add: add_node], on_error: :collect_partial)

      assert node.on_error == :collect_partial
    end

    test "rejects missing name" do
      {:ok, add_node} = ActionNode.new(AddAction)
      assert {:error, _reason} = FanOutNode.new(branches: [add: add_node])
    end

    test "rejects missing branches" do
      assert {:error, _reason} = FanOutNode.new(name: "test")
    end

    test "rejects empty branches" do
      assert {:error, _reason} = FanOutNode.new(name: "test", branches: [])
    end

    test "rejects bare function branches" do
      fun = fn _ctx -> {:ok, %{value: 42}} end

      assert {:error, msg} = FanOutNode.new(name: "test", branches: [calc: fun])
      assert msg =~ "Node struct"
    end

    test "rejects mixed function and node branches" do
      {:ok, add_node} = ActionNode.new(AddAction)
      fun = fn _ctx -> {:ok, %{value: 42}} end

      assert {:error, _msg} = FanOutNode.new(name: "test", branches: [add: add_node, calc: fun])
    end

    test "accepts all Node struct types as branches" do
      {:ok, add_node} = ActionNode.new(AddAction)
      {:ok, echo_node} = ActionNode.new(EchoAction)

      assert {:ok, _node} =
               FanOutNode.new(name: "test", branches: [add: add_node, echo: echo_node])
    end
  end

  describe "run/2 concurrent execution" do
    test "executes branches concurrently and merges results" do
      {:ok, add_node} = ActionNode.new(AddAction)
      {:ok, echo_node} = ActionNode.new(EchoAction)

      {:ok, fan_out} =
        FanOutNode.new(
          name: "parallel",
          branches: [add: add_node, echo: echo_node]
        )

      context = %{value: 1.0, amount: 2.0, message: "hello"}
      assert {:ok, result} = FanOutNode.run(fan_out, context)

      assert %{add: %{result: 3.0}, echo: %{echoed: "hello"}} = result
    end

    test "single branch works" do
      {:ok, add_node} = ActionNode.new(AddAction)
      {:ok, fan_out} = FanOutNode.new(name: "single", branches: [add: add_node])

      assert {:ok, %{add: %{result: 3.0}}} =
               FanOutNode.run(fan_out, %{value: 1.0, amount: 2.0})
    end

    test "each branch receives the same input context" do
      {:ok, echo1} = ActionNode.new(EchoAction)
      {:ok, echo2} = ActionNode.new(EchoAction)

      {:ok, fan_out} =
        FanOutNode.new(
          name: "multi_echo",
          branches: [first: echo1, second: echo2]
        )

      assert {:ok, result} = FanOutNode.run(fan_out, %{message: "shared"})
      assert result.first.echoed == "shared"
      assert result.second.echoed == "shared"
    end
  end

  describe "run/2 error handling" do
    test "fail-fast returns error when any branch fails" do
      {:ok, fail_node} = ActionNode.new(FailAction)
      {:ok, echo_node} = ActionNode.new(EchoAction)

      {:ok, fan_out} =
        FanOutNode.new(
          name: "fail_fast_test",
          branches: [fail: fail_node, echo: echo_node],
          on_error: :fail_fast
        )

      assert {:error, {:branch_failed, _reason}} =
               FanOutNode.run(fan_out, %{message: "hello"})
    end

    test "collect_partial returns all results including errors" do
      {:ok, fail_node} = ActionNode.new(FailAction)
      {:ok, echo_node} = ActionNode.new(EchoAction)

      {:ok, fan_out} =
        FanOutNode.new(
          name: "partial_test",
          branches: [echo: echo_node, fail: fail_node],
          on_error: :collect_partial
        )

      assert {:ok, result} = FanOutNode.run(fan_out, %{message: "hello"})
      assert %{echoed: "hello"} = result.echo
      assert {:error, _reason} = result.fail
    end
  end

  describe "run/2 merge strategies" do
    test "deep_merge scopes results under branch names" do
      {:ok, add_node} = ActionNode.new(AddAction)
      {:ok, echo_node} = ActionNode.new(EchoAction)

      {:ok, fan_out} =
        FanOutNode.new(
          name: "scoped",
          branches: [add: add_node, echo: echo_node]
        )

      assert {:ok, result} = FanOutNode.run(fan_out, %{value: 1.0, amount: 2.0, message: "hi"})
      assert result.add.result == 3.0
      assert result.echo.echoed == "hi"
    end
  end

  describe "run/2 merge with NodeIO" do
    test "merge_results handles NodeIO branches via custom merge" do
      # NodeIO handling is tested via merge_results directly
      branch_results = [
        {:text_branch, NodeIO.text("hello")},
        {:map_branch, %{count: 5}}
      ]

      result = FanOutNode.merge_results(branch_results, :deep_merge)
      assert result.text_branch == %{text: "hello"}
      assert result.map_branch == %{count: 5}
    end
  end

  describe "to_directive/3" do
    test "produces FanOutBranch directives with child_node and fan_out side effect" do
      {:ok, add_node} = ActionNode.new(AddAction)
      {:ok, echo_node} = ActionNode.new(EchoAction)

      {:ok, fan_out} =
        FanOutNode.new(name: "parallel", branches: [add: add_node, echo: echo_node])

      opts = [fan_out_id: "test_123"]

      assert {:ok, directives, side_effects} =
               FanOutNode.to_directive(fan_out, %{value: 1.0, amount: 2.0}, opts)

      assert length(directives) == 2

      Enum.each(directives, fn d ->
        assert %Jido.Composer.Directive.FanOutBranch{} = d
        assert d.fan_out_id == "test_123"
        assert d.result_action == :fan_out_branch_result
        assert is_struct(d.child_node)
        assert is_map(d.params)
      end)

      fan_out_state = Keyword.fetch!(side_effects, :fan_out)
      assert %Jido.Composer.FanOut.State{} = fan_out_state
      assert fan_out_state.id == "test_123"
    end

    test "ActionNode branch directive carries ActionNode as child_node" do
      {:ok, add_node} = ActionNode.new(AddAction)
      {:ok, fan_out} = FanOutNode.new(name: "test", branches: [add: add_node])

      assert {:ok, [directive], _} =
               FanOutNode.to_directive(fan_out, %{value: 1.0}, fan_out_id: "id1")

      assert %ActionNode{action_module: AddAction} = directive.child_node
      assert directive.params == %{value: 1.0}
    end

    test "AgentNode branch directive carries AgentNode as child_node" do
      agent_node = %Jido.Composer.Node.AgentNode{
        agent_module: Jido.Composer.TestAgents.TestWorkflowAgent,
        opts: []
      }

      {:ok, fan_out} = FanOutNode.new(name: "test", branches: [agent: agent_node])

      assert {:ok, [directive], _} =
               FanOutNode.to_directive(fan_out, %{x: 1}, fan_out_id: "id2")

      assert %Jido.Composer.Node.AgentNode{} = directive.child_node
    end

    test "mixed branch types produce correct child_node types" do
      {:ok, add_node} = ActionNode.new(AddAction)

      agent_node = %Jido.Composer.Node.AgentNode{
        agent_module: Jido.Composer.TestAgents.TestWorkflowAgent,
        opts: []
      }

      {:ok, fan_out} =
        FanOutNode.new(name: "mixed", branches: [add: add_node, agent: agent_node])

      assert {:ok, directives, _} =
               FanOutNode.to_directive(fan_out, %{value: 1.0}, fan_out_id: "id3")

      add_directive = Enum.find(directives, &(&1.branch_name == :add))
      agent_directive = Enum.find(directives, &(&1.branch_name == :agent))

      assert %ActionNode{} = add_directive.child_node
      assert %Jido.Composer.Node.AgentNode{} = agent_directive.child_node
    end

    test "nested FanOutNode as branch child" do
      {:ok, inner_add} = ActionNode.new(AddAction)
      {:ok, inner_fan_out} = FanOutNode.new(name: "inner", branches: [add: inner_add])

      {:ok, outer_fan_out} =
        FanOutNode.new(name: "outer", branches: [nested: inner_fan_out])

      assert {:ok, [directive], _} =
               FanOutNode.to_directive(outer_fan_out, %{value: 1.0}, fan_out_id: "nested_id")

      assert %FanOutNode{name: "inner"} = directive.child_node
    end

    test "respects max_concurrency by queuing excess branches" do
      {:ok, add_node} = ActionNode.new(AddAction)
      {:ok, echo_node} = ActionNode.new(EchoAction)

      {:ok, fan_out} =
        FanOutNode.new(
          name: "parallel",
          branches: [add: add_node, echo: echo_node],
          max_concurrency: 1
        )

      assert {:ok, directives, side_effects} =
               FanOutNode.to_directive(fan_out, %{}, fan_out_id: "test_456")

      assert length(directives) == 1

      fan_out_state = Keyword.fetch!(side_effects, :fan_out)
      assert MapSet.size(fan_out_state.pending_branches) == 1
      assert length(fan_out_state.queued_branches) == 1
    end
  end

  describe "to_tool_spec/1" do
    test "returns nil (FanOutNode cannot act as LLM tool)" do
      {:ok, add_node} = ActionNode.new(AddAction)
      {:ok, fan_out} = FanOutNode.new(name: "test", branches: [add: add_node])
      assert FanOutNode.to_tool_spec(fan_out) == nil
    end
  end

  describe "Node behaviour" do
    test "FanOutNode declares Node behaviour" do
      behaviours =
        FanOutNode.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Jido.Composer.Node in behaviours
    end

    test "run/3 is implemented and returns {:ok, map}" do
      {:ok, add_node} = ActionNode.new(AddAction)
      {:ok, fan_out} = FanOutNode.new(name: "test", branches: [add: add_node])
      assert {:ok, %{add: %{result: 3.0}}} = FanOutNode.run(fan_out, %{value: 1.0, amount: 2.0})
    end
  end

  describe "metadata" do
    test "name/1 returns the configured name" do
      {:ok, add_node} = ActionNode.new(AddAction)
      {:ok, node} = FanOutNode.new(name: "my_fan_out", branches: [add: add_node])
      assert FanOutNode.name(node) == "my_fan_out"
    end

    test "description/1 returns a generated description" do
      {:ok, add_node} = ActionNode.new(AddAction)
      {:ok, node} = FanOutNode.new(name: "my_fan_out", branches: [add: add_node])
      desc = FanOutNode.description(node)
      assert is_binary(desc)
      assert desc =~ "1"
    end
  end
end
