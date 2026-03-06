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

    test "branches execute in parallel (speedup test)" do
      # Use function-based branches to test parallelism with sleep
      {:ok, fan_out} =
        FanOutNode.new(
          name: "perf",
          branches: [
            a: fn _ctx ->
              Process.sleep(100)
              {:ok, %{done: true}}
            end,
            b: fn _ctx ->
              Process.sleep(100)
              {:ok, %{done: true}}
            end,
            c: fn _ctx ->
              Process.sleep(100)
              {:ok, %{done: true}}
            end
          ]
        )

      {time_us, {:ok, result}} = :timer.tc(fn -> FanOutNode.run(fan_out, %{}) end)
      time_ms = time_us / 1000

      assert map_size(result) == 3
      # Sequential would be ~300ms; parallel should be ~100ms
      assert time_ms < 250
    end
  end

  describe "run/2 with function branches" do
    test "accepts anonymous function branches" do
      {:ok, fan_out} =
        FanOutNode.new(
          name: "fn_branches",
          branches: [
            compute: fn _ctx -> {:ok, %{value: 42}} end,
            lookup: fn _ctx -> {:ok, %{found: true}} end
          ]
        )

      assert {:ok, %{compute: %{value: 42}, lookup: %{found: true}}} =
               FanOutNode.run(fan_out, %{})
    end

    test "function branches receive context" do
      {:ok, fan_out} =
        FanOutNode.new(
          name: "ctx_test",
          branches: [
            reader: fn ctx -> {:ok, %{input: ctx.input}} end
          ]
        )

      assert {:ok, %{reader: %{input: "test_data"}}} =
               FanOutNode.run(fan_out, %{input: "test_data"})
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

    test "timeout causes error in fail-fast mode" do
      {:ok, fan_out} =
        FanOutNode.new(
          name: "timeout_test",
          branches: [
            fast: fn _ctx -> {:ok, %{done: true}} end,
            slow: fn _ctx ->
              Process.sleep(5000)
              {:ok, %{done: true}}
            end
          ],
          timeout: 200
        )

      assert {:error, {:branch_crashed, _reason}} = FanOutNode.run(fan_out, %{})
    end
  end

  describe "run/2 merge strategies" do
    test "deep_merge scopes results under branch names" do
      {:ok, fan_out} =
        FanOutNode.new(
          name: "scoped",
          branches: [
            financial: fn _ctx -> {:ok, %{score: 85, risk: :low}} end,
            legal: fn _ctx -> {:ok, %{status: :clear}} end
          ]
        )

      assert {:ok, result} = FanOutNode.run(fan_out, %{})
      assert result.financial.score == 85
      assert result.legal.status == :clear
    end

    test "custom merge function receives branch results" do
      sum_merge = fn results ->
        total = Enum.reduce(results, 0, fn {_name, result}, acc -> acc + result.value end)
        %{total: total}
      end

      {:ok, fan_out} =
        FanOutNode.new(
          name: "custom_merge",
          branches: [
            a: fn _ctx -> {:ok, %{value: 10}} end,
            b: fn _ctx -> {:ok, %{value: 20}} end,
            c: fn _ctx -> {:ok, %{value: 30}} end
          ],
          merge: sum_merge
        )

      assert {:ok, %{total: 60}} = FanOutNode.run(fan_out, %{})
    end
  end

  describe "run/2 merge with NodeIO" do
    test "merge_results handles mixed NodeIO and bare map branches" do
      {:ok, fan_out} =
        FanOutNode.new(
          name: "mixed_nodeio",
          branches: [
            text_branch: fn _ctx -> {:ok, NodeIO.text("hello")} end,
            map_branch: fn _ctx -> {:ok, %{count: 5}} end,
            obj_branch: fn _ctx -> {:ok, NodeIO.object(%{score: 0.9})} end,
            nodeio_map_branch: fn _ctx -> {:ok, NodeIO.map(%{items: [1, 2]})} end
          ]
        )

      assert {:ok, result} = FanOutNode.run(fan_out, %{})
      assert result.text_branch == %{text: "hello"}
      assert result.map_branch == %{count: 5}
      assert result.obj_branch == %{object: %{score: 0.9}}
      assert result.nodeio_map_branch == %{items: [1, 2]}
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
