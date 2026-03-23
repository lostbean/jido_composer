defmodule Jido.Composer.Node.MapNodeTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.Directive.FanOutBranch
  alias Jido.Composer.FanOut.State, as: FanOutState
  alias Jido.Composer.Node.ActionNode
  alias Jido.Composer.Node.FanOutNode
  alias Jido.Composer.Node.MapNode

  # -- Test Actions --

  defmodule DoubleValueAction do
    @moduledoc false
    use Jido.Action,
      name: "double_value",
      description: "Doubles a numeric value",
      schema: [
        value: [type: :float, required: true, doc: "The value to double"]
      ]

    def run(%{value: value}, _context) do
      {:ok, %{doubled: value * 2}}
    end
  end

  defmodule ProcessItemAction do
    @moduledoc false
    use Jido.Action,
      name: "process_item",
      description: "Processes a string item by uppercasing it",
      schema: [
        item: [type: :string, required: true, doc: "The item to process"]
      ]

    def run(%{item: item}, _context) do
      {:ok, %{processed: String.upcase(item)}}
    end
  end

  defmodule FailingAction do
    @moduledoc false
    use Jido.Action,
      name: "failing_action",
      description: "Always fails",
      schema: []

    def run(_params, _context) do
      {:error, "element processing failed"}
    end
  end

  defmodule AddTenAction do
    @moduledoc false
    use Jido.Action,
      name: "add_ten",
      description: "Adds ten to a value",
      schema: [value: [type: :float, required: true]]

    def run(%{value: value}, _context) do
      {:ok, %{result: value + 10}}
    end
  end

  # -- new/1 --

  describe "new/1 — :node option" do
    test "accepts bare action module (auto-wraps in ActionNode)" do
      assert {:ok, node} =
               MapNode.new(name: :process, over: :items, node: DoubleValueAction)

      assert %ActionNode{action_module: DoubleValueAction} = node.node
    end

    test "accepts ActionNode struct directly" do
      {:ok, action_node} = ActionNode.new(DoubleValueAction)

      assert {:ok, node} =
               MapNode.new(name: :process, over: :items, node: action_node)

      assert %ActionNode{action_module: DoubleValueAction} = node.node
    end

    test "accepts FanOutNode struct" do
      {:ok, add_node} = ActionNode.new(DoubleValueAction)
      {:ok, add_ten_node} = ActionNode.new(AddTenAction)

      {:ok, fan_out} =
        FanOutNode.new(name: "inner", branches: [double: add_node, add_ten: add_ten_node])

      assert {:ok, node} = MapNode.new(name: :process, over: :items, node: fan_out)
      assert %FanOutNode{} = node.node
    end

    test "accepts AgentNode struct" do
      agent_node = %Jido.Composer.Node.AgentNode{
        agent_module: Jido.Composer.TestAgents.TestWorkflowAgent,
        opts: []
      }

      assert {:ok, node} = MapNode.new(name: :process, over: :items, node: agent_node)
      assert %Jido.Composer.Node.AgentNode{} = node.node
    end

    test "accepts HumanNode struct" do
      {:ok, human_node} =
        Jido.Composer.Node.HumanNode.new(
          name: "approve",
          description: "Approve item",
          prompt: "Do you approve?"
        )

      assert {:ok, node} = MapNode.new(name: :process, over: :items, node: human_node)
      assert %Jido.Composer.Node.HumanNode{} = node.node
    end

    test "rejects invalid values" do
      assert {:error, _} = MapNode.new(name: :process, over: :items, node: "not_a_module")
      assert {:error, _} = MapNode.new(name: :process, over: :items, node: Enum)
    end

    test "requires name" do
      assert {:error, _} = MapNode.new(over: :items, node: DoubleValueAction)
    end

    test "requires over" do
      assert {:error, _} = MapNode.new(name: :process, node: DoubleValueAction)
    end

    test "requires node (or action)" do
      assert {:error, _} = MapNode.new(name: :process, over: :items)
    end
  end

  describe "new/1 — backward compat :action option" do
    test ":action is accepted and auto-wraps in ActionNode" do
      assert {:ok, node} =
               MapNode.new(name: :process, over: :items, action: DoubleValueAction)

      assert %ActionNode{action_module: DoubleValueAction} = node.node
    end

    test ":node takes precedence over :action" do
      {:ok, add_ten_node} = ActionNode.new(AddTenAction)

      assert {:ok, node} =
               MapNode.new(
                 name: :process,
                 over: :items,
                 node: add_ten_node,
                 action: DoubleValueAction
               )

      assert %ActionNode{action_module: AddTenAction} = node.node
    end

    test "rejects invalid action module" do
      assert {:error, _} = MapNode.new(name: :process, over: :items, action: NotAModule)
    end
  end

  describe "new/1 — options" do
    test "rejects invalid on_error value" do
      assert {:error, "on_error must be :fail_fast or :collect_partial"} =
               MapNode.new(
                 name: :process,
                 over: :items,
                 node: DoubleValueAction,
                 on_error: :bogus
               )
    end

    test "defaults timeout to 30_000" do
      {:ok, node} = MapNode.new(name: :process, over: :items, node: DoubleValueAction)
      assert node.timeout == 30_000
    end

    test "defaults on_error to :fail_fast" do
      {:ok, node} = MapNode.new(name: :process, over: :items, node: DoubleValueAction)
      assert node.on_error == :fail_fast
    end

    test "defaults max_concurrency to nil" do
      {:ok, node} = MapNode.new(name: :process, over: :items, node: DoubleValueAction)
      assert node.max_concurrency == nil
    end

    test "accepts custom max_concurrency and timeout" do
      {:ok, node} =
        MapNode.new(
          name: :process,
          over: :items,
          node: DoubleValueAction,
          max_concurrency: 2,
          timeout: 60_000
        )

      assert node.max_concurrency == 2
      assert node.timeout == 60_000
    end

    test "accepts over as a list path" do
      {:ok, node} =
        MapNode.new(
          name: :process,
          over: [:generate, :items],
          node: DoubleValueAction
        )

      assert node.over == [:generate, :items]
    end
  end

  # -- run/3 --

  describe "run/3 with ActionNode child" do
    test "runs action on each map element, returns ordered results" do
      {:ok, node} = MapNode.new(name: :process, over: :items, node: DoubleValueAction)
      context = %{items: [%{value: 1.0}, %{value: 2.0}, %{value: 3.0}]}

      assert {:ok, %{results: results}} = MapNode.run(node, context)
      assert results == [%{doubled: 2.0}, %{doubled: 4.0}, %{doubled: 6.0}]
    end

    test "wraps non-map elements as %{item: element}" do
      {:ok, node} = MapNode.new(name: :process, over: :items, node: ProcessItemAction)
      context = %{items: ["hello", "world"]}

      assert {:ok, %{results: results}} = MapNode.run(node, context)
      assert results == [%{processed: "HELLO"}, %{processed: "WORLD"}]
    end

    test "empty list returns {:ok, %{results: []}}" do
      {:ok, node} = MapNode.new(name: :process, over: :items, node: DoubleValueAction)
      context = %{items: []}

      assert {:ok, %{results: []}} = MapNode.run(node, context)
    end

    test "missing context key returns {:ok, %{results: []}}" do
      {:ok, node} = MapNode.new(name: :process, over: :items, node: DoubleValueAction)
      context = %{other: "data"}

      assert {:ok, %{results: []}} = MapNode.run(node, context)
    end

    test "preserves input order" do
      {:ok, node} = MapNode.new(name: :process, over: :items, node: DoubleValueAction)
      items = Enum.map(1..10, &%{value: &1 * 1.0})
      context = %{items: items}

      assert {:ok, %{results: results}} = MapNode.run(node, context)
      expected = Enum.map(1..10, &%{doubled: &1 * 2.0})
      assert results == expected
    end

    test "max_concurrency limits parallel execution" do
      {:ok, node} =
        MapNode.new(
          name: :process,
          over: :items,
          node: DoubleValueAction,
          max_concurrency: 1
        )

      context = %{items: [%{value: 1.0}, %{value: 2.0}]}

      assert {:ok, %{results: results}} = MapNode.run(node, context)
      assert results == [%{doubled: 2.0}, %{doubled: 4.0}]
    end

    test "fail-fast on element error" do
      {:ok, node} = MapNode.new(name: :process, over: :items, node: FailingAction)
      context = %{items: [%{}, %{}]}

      assert {:error, _} = MapNode.run(node, context)
    end

    test "supports over as list path" do
      {:ok, node} =
        MapNode.new(name: :process, over: [:generate, :items], node: DoubleValueAction)

      context = %{generate: %{items: [%{value: 5.0}]}}

      assert {:ok, %{results: [%{doubled: 10.0}]}} = MapNode.run(node, context)
    end
  end

  describe "run/3 with FanOutNode child" do
    test "maps fan-out over collection" do
      {:ok, double_node} = ActionNode.new(DoubleValueAction)
      {:ok, add_ten_node} = ActionNode.new(AddTenAction)

      {:ok, fan_out} =
        FanOutNode.new(name: "inner", branches: [double: double_node, add_ten: add_ten_node])

      {:ok, node} = MapNode.new(name: :process, over: :items, node: fan_out)
      context = %{items: [%{value: 5.0}]}

      assert {:ok, %{results: [result]}} = MapNode.run(node, context)
      assert result.double.doubled == 10.0
      assert result.add_ten.result == 15.0
    end

    test "empty collection with FanOutNode child returns %{results: []}" do
      {:ok, double_node} = ActionNode.new(DoubleValueAction)
      {:ok, fan_out} = FanOutNode.new(name: "inner", branches: [double: double_node])

      {:ok, node} = MapNode.new(name: :process, over: :items, node: fan_out)

      assert {:ok, %{results: []}} = MapNode.run(node, %{items: []})
    end
  end

  # -- to_directive/3 --

  describe "to_directive/3" do
    test "generates FanOutBranch per element with child_node and item_N names" do
      {:ok, node} = MapNode.new(name: :process, over: :items, node: DoubleValueAction)
      context = %{items: [%{value: 1.0}, %{value: 2.0}, %{value: 3.0}]}

      assert {:ok, directives, fan_out: %FanOutState{}} =
               MapNode.to_directive(node, context, fan_out_id: "test-id")

      assert length(directives) == 3
      assert Enum.all?(directives, &match?(%FanOutBranch{}, &1))

      names = Enum.map(directives, & &1.branch_name)
      assert names == [:item_0, :item_1, :item_2]

      # Each directive carries the ActionNode as child_node
      Enum.each(directives, fn d ->
        assert %ActionNode{action_module: DoubleValueAction} = d.child_node
        assert is_map(d.params)
      end)
    end

    test "FanOutNode child produces FanOutBranch with FanOutNode child_node" do
      {:ok, double_node} = ActionNode.new(DoubleValueAction)
      {:ok, fan_out} = FanOutNode.new(name: "inner", branches: [double: double_node])

      {:ok, node} = MapNode.new(name: :process, over: :items, node: fan_out)
      context = %{items: [%{value: 1.0}, %{value: 2.0}]}

      assert {:ok, directives, fan_out: _state} =
               MapNode.to_directive(node, context, fan_out_id: "test-id")

      assert length(directives) == 2

      Enum.each(directives, fn d ->
        assert %FanOutNode{} = d.child_node
      end)
    end

    test "returns fan_out side effect with FanOut.State" do
      {:ok, node} = MapNode.new(name: :process, over: :items, node: DoubleValueAction)
      context = %{items: [%{value: 1.0}]}

      assert {:ok, _directives, fan_out: state} =
               MapNode.to_directive(node, context, fan_out_id: "test-id")

      assert %FanOutState{} = state
      assert state.merge == :ordered_list
      assert state.id == "test-id"
    end

    test "empty list returns single RunInstruction, no fan_out side effect" do
      {:ok, node} = MapNode.new(name: :process, over: :items, node: DoubleValueAction)
      context = %{items: []}

      assert {:ok, [directive]} = MapNode.to_directive(node, context, fan_out_id: "test-id")
      assert %Jido.Agent.Directive.RunInstruction{} = directive
      assert directive.instruction.action == MapNode.EmptyResult
    end

    test "respects max_concurrency — dispatches batch, queues rest" do
      {:ok, node} =
        MapNode.new(
          name: :process,
          over: :items,
          node: DoubleValueAction,
          max_concurrency: 2
        )

      context = %{items: [%{value: 1.0}, %{value: 2.0}, %{value: 3.0}, %{value: 4.0}]}

      assert {:ok, directives, fan_out: state} =
               MapNode.to_directive(node, context, fan_out_id: "test-id")

      assert length(directives) == 2
      assert length(state.queued_branches) == 2
    end
  end

  # -- Metadata --

  describe "metadata" do
    test "name/1 returns configured name" do
      {:ok, node} = MapNode.new(name: :process, over: :items, node: DoubleValueAction)
      assert MapNode.name(node) == "process"
    end

    test "description/1 uses child node dispatch_name" do
      {:ok, node} = MapNode.new(name: :process, over: :items, node: DoubleValueAction)
      desc = MapNode.description(node)
      assert desc =~ "items"
    end

    test "description/1 with FanOutNode child" do
      {:ok, double_node} = ActionNode.new(DoubleValueAction)
      {:ok, fan_out} = FanOutNode.new(name: "inner_fo", branches: [double: double_node])

      {:ok, node} = MapNode.new(name: :process, over: :items, node: fan_out)
      desc = MapNode.description(node)
      assert desc =~ "items"
    end

    test "to_tool_spec/1 returns nil" do
      {:ok, node} = MapNode.new(name: :process, over: :items, node: DoubleValueAction)
      assert MapNode.to_tool_spec(node) == nil
    end
  end
end
