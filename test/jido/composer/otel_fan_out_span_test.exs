defmodule Jido.Composer.OtelFanOutSpanTest do
  @moduledoc """
  Tests that MapNode/FanOutBranch workflows produce correctly nested OTel spans.

  Verifies three fixes:
  1. OTel context propagation into Task.async_stream (dsl.ex, map_node.ex)
  2. Per-branch TOOL span creation in execute_fan_out_branch (dsl.ex)
  3. Fan-out node span is finished before transitioning (strategy.ex)
  """
  use ExUnit.Case, async: false

  alias Jido.Composer.Node.MapNode
  alias Jido.Composer.OtelTestHelper, as: OTH

  @moduletag :capture_log

  # -- Test Actions --

  defmodule DoubleAction do
    use Jido.Action,
      name: "double_value",
      description: "Doubles a numeric value",
      schema: [value: [type: :float, required: true]]

    def run(%{value: value}, _context), do: {:ok, %{doubled: value * 2}}
  end

  defmodule SumAction do
    use Jido.Action,
      name: "sum_results",
      description: "Sums doubled values",
      schema: []

    def run(params, _context) do
      results = get_in(params, [:process, :results]) || []
      total = Enum.reduce(results, 0.0, fn item, acc -> acc + (item[:doubled] || 0) end)
      {:ok, %{total: total}}
    end
  end

  # -- Workflow with MapNode followed by a regular node --

  defmodule MapThenSumWorkflow do
    {:ok, map_node} =
      MapNode.new(
        name: :process,
        over: [:generate, :items],
        node: DoubleAction
      )

    use Jido.Composer.Workflow,
      name: "map_then_sum",
      description: "Map over items then aggregate",
      nodes: %{
        generate: Jido.Composer.OtelFanOutSpanTest.GenerateAction,
        process: map_node,
        aggregate: SumAction
      },
      transitions: %{
        {:generate, :ok} => :process,
        {:process, :ok} => :aggregate,
        {:aggregate, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :generate
  end

  defmodule GenerateAction do
    use Jido.Action,
      name: "generate_items",
      description: "Produces items for the MapNode",
      schema: []

    def run(_params, _context) do
      {:ok, %{items: [%{value: 1.0}, %{value: 2.0}]}}
    end
  end

  # -- Setup --

  setup do
    handler_state = OTH.setup_otel_capture(self())
    on_exit(fn -> OTH.teardown_otel(handler_state) end)
    :ok
  end

  # -- Tests --

  describe "MapNode fan-out OTel span hierarchy" do
    test "branch spans share trace_id with parent workflow" do
      {:ok, result} =
        MapThenSumWorkflow.new()
        |> MapThenSumWorkflow.run_sync(%{})

      assert result[:aggregate][:total] == 6.0

      spans = OTH.collect_spans()
      agent_span = OTH.find_span(spans, "map_then_sum")

      branch_spans = OTH.find_spans(spans, "double_value")

      assert agent_span != nil,
             "Expected AGENT span, got: #{inspect(Enum.map(spans, &OTH.span_name/1))}"

      assert length(branch_spans) == 2,
             "Expected 2 branch spans, got: #{inspect(Enum.map(spans, &OTH.span_name/1))}"

      OTH.assert_same_trace([agent_span | branch_spans])
    end

    test "branch spans are children of the MapNode's node span" do
      {:ok, _result} =
        MapThenSumWorkflow.new()
        |> MapThenSumWorkflow.run_sync(%{})

      spans = OTH.collect_spans()

      # The MapNode's node span is named after the wrapped action
      process_span = OTH.find_span(spans, "process")

      branch_spans = OTH.find_spans(spans, "double_value")

      assert process_span != nil,
             "Expected node span for 'process', got: #{inspect(Enum.map(spans, &OTH.span_name/1))}"

      for branch <- branch_spans do
        OTH.assert_parent_child(process_span, branch)
      end
    end

    test "MapNode node span and subsequent node span are siblings under AGENT" do
      {:ok, _result} =
        MapThenSumWorkflow.new()
        |> MapThenSumWorkflow.run_sync(%{})

      spans = OTH.collect_spans()
      agent_span = OTH.find_span(spans, "map_then_sum")
      process_span = OTH.find_span(spans, "process")
      aggregate_span = OTH.find_span(spans, "sum_results")

      assert agent_span != nil,
             "Expected AGENT span, got: #{inspect(Enum.map(spans, &OTH.span_name/1))}"

      assert process_span != nil,
             "Expected 'process' node span, got: #{inspect(Enum.map(spans, &OTH.span_name/1))}"

      assert aggregate_span != nil,
             "Expected 'sum_results' node span, got: #{inspect(Enum.map(spans, &OTH.span_name/1))}"

      # Both node spans should be children of the AGENT span (siblings),
      # NOT aggregate nested under process.
      OTH.assert_parent_child(agent_span, process_span)
      OTH.assert_parent_child(agent_span, aggregate_span)
      OTH.assert_siblings(process_span, aggregate_span)
    end
  end
end
