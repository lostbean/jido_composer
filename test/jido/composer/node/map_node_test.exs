defmodule Jido.Composer.Node.MapNodeTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.Directive.FanOutBranch
  alias Jido.Composer.FanOut.State, as: FanOutState
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

  # -- new/1 --

  describe "new/1" do
    test "creates MapNode with valid opts" do
      assert {:ok, node} =
               MapNode.new(
                 name: :process,
                 over: :items,
                 action: DoubleValueAction
               )

      assert node.name == :process
      assert node.over == :items
      assert node.action == DoubleValueAction
    end

    test "requires name" do
      assert {:error, _} = MapNode.new(over: :items, action: DoubleValueAction)
    end

    test "requires over" do
      assert {:error, _} = MapNode.new(name: :process, action: DoubleValueAction)
    end

    test "requires action" do
      assert {:error, _} = MapNode.new(name: :process, over: :items)
    end

    test "rejects invalid action module" do
      assert {:error, _} = MapNode.new(name: :process, over: :items, action: NotAModule)
    end

    test "rejects invalid on_error value" do
      assert {:error, "on_error must be :fail_fast or :collect_partial"} =
               MapNode.new(
                 name: :process,
                 over: :items,
                 action: DoubleValueAction,
                 on_error: :bogus
               )
    end

    test "defaults timeout to 30_000" do
      {:ok, node} = MapNode.new(name: :process, over: :items, action: DoubleValueAction)
      assert node.timeout == 30_000
    end

    test "defaults on_error to :fail_fast" do
      {:ok, node} = MapNode.new(name: :process, over: :items, action: DoubleValueAction)
      assert node.on_error == :fail_fast
    end

    test "defaults max_concurrency to nil" do
      {:ok, node} = MapNode.new(name: :process, over: :items, action: DoubleValueAction)
      assert node.max_concurrency == nil
    end

    test "accepts custom max_concurrency and timeout" do
      {:ok, node} =
        MapNode.new(
          name: :process,
          over: :items,
          action: DoubleValueAction,
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
          action: DoubleValueAction
        )

      assert node.over == [:generate, :items]
    end
  end

  # -- run/3 --

  describe "run/3" do
    test "runs action on each map element, returns ordered results" do
      {:ok, node} = MapNode.new(name: :process, over: :items, action: DoubleValueAction)
      context = %{items: [%{value: 1.0}, %{value: 2.0}, %{value: 3.0}]}

      assert {:ok, %{results: results}} = MapNode.run(node, context)
      assert results == [%{doubled: 2.0}, %{doubled: 4.0}, %{doubled: 6.0}]
    end

    test "wraps non-map elements as %{item: element}" do
      {:ok, node} = MapNode.new(name: :process, over: :items, action: ProcessItemAction)
      context = %{items: ["hello", "world"]}

      assert {:ok, %{results: results}} = MapNode.run(node, context)
      assert results == [%{processed: "HELLO"}, %{processed: "WORLD"}]
    end

    test "empty list returns {:ok, %{results: []}}" do
      {:ok, node} = MapNode.new(name: :process, over: :items, action: DoubleValueAction)
      context = %{items: []}

      assert {:ok, %{results: []}} = MapNode.run(node, context)
    end

    test "missing context key returns {:ok, %{results: []}}" do
      {:ok, node} = MapNode.new(name: :process, over: :items, action: DoubleValueAction)
      context = %{other: "data"}

      assert {:ok, %{results: []}} = MapNode.run(node, context)
    end

    test "preserves input order" do
      {:ok, node} = MapNode.new(name: :process, over: :items, action: DoubleValueAction)
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
          action: DoubleValueAction,
          max_concurrency: 1
        )

      context = %{items: [%{value: 1.0}, %{value: 2.0}]}

      assert {:ok, %{results: results}} = MapNode.run(node, context)
      assert results == [%{doubled: 2.0}, %{doubled: 4.0}]
    end

    test "fail-fast on element error" do
      {:ok, node} = MapNode.new(name: :process, over: :items, action: FailingAction)
      context = %{items: [%{}, %{}]}

      assert {:error, _} = MapNode.run(node, context)
    end

    test "supports over as list path" do
      {:ok, node} =
        MapNode.new(name: :process, over: [:generate, :items], action: DoubleValueAction)

      context = %{generate: %{items: [%{value: 5.0}]}}

      assert {:ok, %{results: [%{doubled: 10.0}]}} = MapNode.run(node, context)
    end
  end

  # -- to_directive/3 --

  describe "to_directive/3" do
    test "generates FanOutBranch per element with item_N names" do
      {:ok, node} = MapNode.new(name: :process, over: :items, action: DoubleValueAction)
      context = %{items: [%{value: 1.0}, %{value: 2.0}, %{value: 3.0}]}

      assert {:ok, directives, fan_out: %FanOutState{}} =
               MapNode.to_directive(node, context, fan_out_id: "test-id")

      assert length(directives) == 3
      assert Enum.all?(directives, &match?(%FanOutBranch{}, &1))

      names = Enum.map(directives, & &1.branch_name)
      assert names == [:item_0, :item_1, :item_2]
    end

    test "returns fan_out side effect with FanOut.State" do
      {:ok, node} = MapNode.new(name: :process, over: :items, action: DoubleValueAction)
      context = %{items: [%{value: 1.0}]}

      assert {:ok, _directives, fan_out: state} =
               MapNode.to_directive(node, context, fan_out_id: "test-id")

      assert %FanOutState{} = state
      assert state.merge == :ordered_list
      assert state.id == "test-id"
    end

    test "empty list returns single RunInstruction, no fan_out side effect" do
      {:ok, node} = MapNode.new(name: :process, over: :items, action: DoubleValueAction)
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
          action: DoubleValueAction,
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
      {:ok, node} = MapNode.new(name: :process, over: :items, action: DoubleValueAction)
      assert MapNode.name(node) == "process"
    end

    test "description/1 describes action and over key" do
      {:ok, node} = MapNode.new(name: :process, over: :items, action: DoubleValueAction)
      desc = MapNode.description(node)
      assert desc =~ "items"
    end

    test "to_tool_spec/1 returns nil" do
      {:ok, node} = MapNode.new(name: :process, over: :items, action: DoubleValueAction)
      assert MapNode.to_tool_spec(node) == nil
    end
  end
end
