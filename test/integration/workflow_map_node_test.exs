defmodule Jido.Composer.Integration.WorkflowMapNodeTest do
  use ExUnit.Case, async: true

  alias Jido.Agent.Directive
  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.Composer.Directive.FanOutBranch
  alias Jido.Composer.Node.MapNode

  # -- Test Actions --

  defmodule GenerateItemsAction do
    @moduledoc false
    use Jido.Action,
      name: "generate_items",
      description: "Generates a list of items",
      schema: []

    def run(_params, _context) do
      {:ok, %{items: [%{value: 1.0}, %{value: 2.0}, %{value: 3.0}]}}
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

  defmodule AggregateAction do
    @moduledoc false
    use Jido.Action,
      name: "aggregate",
      description: "Sums the doubled values from processed results",
      schema: [
        process: [type: :map, required: false, doc: "Results from process step"]
      ]

    def run(params, _context) do
      results = get_in(params, [:process, :results]) || []
      total = Enum.reduce(results, 0.0, fn item, acc -> acc + (item[:doubled] || 0) end)
      {:ok, %{total: total}}
    end
  end

  defmodule FailElementAction do
    @moduledoc false
    use Jido.Action,
      name: "fail_element",
      description: "Always fails",
      schema: []

    def run(_params, _context) do
      {:error, "element failed"}
    end
  end

  # -- Workflows --

  defmodule MapWorkflow do
    {:ok, map_node} =
      MapNode.new(
        name: :process,
        over: [:generate, :items],
        node: DoubleValueAction
      )

    use Jido.Composer.Workflow,
      name: "map_workflow",
      description: "Generate items, map over them, aggregate",
      nodes: %{
        generate: GenerateItemsAction,
        process: map_node,
        aggregate: AggregateAction
      },
      transitions: %{
        {:generate, :ok} => :process,
        {:process, :ok} => :aggregate,
        {:aggregate, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :generate
  end

  defmodule SingleMapWorkflow do
    {:ok, map_node} =
      MapNode.new(
        name: :compute,
        over: :items,
        node: DoubleValueAction
      )

    use Jido.Composer.Workflow,
      name: "single_map_workflow",
      description: "MapNode as only step",
      nodes: %{
        compute: map_node
      },
      transitions: %{
        {:compute, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :compute
  end

  defmodule FailingMapWorkflow do
    {:ok, map_node} =
      MapNode.new(
        name: :process,
        over: :items,
        node: FailElementAction
      )

    use Jido.Composer.Workflow,
      name: "failing_map_workflow",
      nodes: %{
        process: map_node
      },
      transitions: %{
        {:process, :ok} => :done,
        {:process, :error} => :failed,
        {:_, :error} => :failed
      },
      initial: :process
  end

  defmodule EmptyMapWorkflow do
    {:ok, map_node} =
      MapNode.new(
        name: :process,
        over: :missing_key,
        node: DoubleValueAction
      )

    use Jido.Composer.Workflow,
      name: "empty_map_workflow",
      nodes: %{
        process: map_node
      },
      transitions: %{
        {:process, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :process
  end

  # -- Helpers --

  defp execute_workflow(agent_module, agent, directives) do
    run_directive_loop(agent_module, agent, directives)
  end

  defp run_directive_loop(_agent_module, agent, []), do: agent

  defp run_directive_loop(agent_module, agent, [directive | rest]) do
    case directive do
      %Directive.RunInstruction{instruction: instr, result_action: result_action} ->
        payload = execute_instruction(instr)
        {agent, new_directives} = agent_module.cmd(agent, {result_action, payload})
        run_directive_loop(agent_module, agent, new_directives ++ rest)

      %FanOutBranch{} = _first_branch ->
        {fan_out_directives, remaining} =
          Enum.split_with([directive | rest], &match?(%FanOutBranch{}, &1))

        agent = execute_fan_out_directives(agent_module, agent, fan_out_directives)
        run_directive_loop(agent_module, agent, remaining)

      _other ->
        run_directive_loop(agent_module, agent, rest)
    end
  end

  defp execute_fan_out_directives(agent_module, agent, fan_out_directives) do
    results =
      Enum.map(fan_out_directives, fn %FanOutBranch{} = branch ->
        result = execute_fan_out_branch(branch)
        {branch.branch_name, result}
      end)

    {agent, final_directives} =
      Enum.reduce(results, {agent, []}, fn {branch_name, result}, {acc, _dirs} ->
        agent_module.cmd(
          acc,
          {:fan_out_branch_result, %{branch_name: branch_name, result: result}}
        )
      end)

    run_directive_loop(agent_module, agent, final_directives)
  end

  defp execute_fan_out_branch(%FanOutBranch{child_node: child_node, params: params}) do
    child_node.__struct__.run(child_node, params, [])
  end

  defp execute_instruction(%Jido.Instruction{action: action_module, params: params}) do
    case Jido.Exec.run(action_module, params) do
      {:ok, result} ->
        %{
          status: :ok,
          result: result,
          instruction: %Jido.Instruction{action: action_module, params: params},
          effects: [],
          meta: %{}
        }

      {:error, reason} ->
        %{
          status: :error,
          result: %{error: reason},
          instruction: %Jido.Instruction{action: action_module, params: params},
          effects: [],
          meta: %{}
        }
    end
  end

  # -- Tests --

  describe "MapNode full pipeline" do
    test "generate → map → aggregate produces correct total" do
      agent = MapWorkflow.new()
      {agent, directives} = MapWorkflow.run(agent, %{})

      agent = execute_workflow(MapWorkflow, agent, directives)

      strat = StratState.get(agent)
      assert strat.machine.status == :done
      assert StratState.status(agent) == :success

      ctx = strat.machine.context.working
      # (1+2+3)*2 = 12
      assert ctx[:aggregate][:total] == 12.0
    end

    test "MapNode result is scoped under state name" do
      agent = MapWorkflow.new()
      {agent, directives} = MapWorkflow.run(agent, %{})
      agent = execute_workflow(MapWorkflow, agent, directives)

      strat = StratState.get(agent)
      ctx = strat.machine.context.working
      assert Map.has_key?(ctx, :process)
      assert is_list(ctx[:process][:results])
    end
  end

  describe "MapNode as single step" do
    test "maps items from initial context" do
      agent = SingleMapWorkflow.new()

      assert {:ok, result} =
               SingleMapWorkflow.run_sync(agent, %{items: [%{value: 10.0}, %{value: 20.0}]})

      assert result[:compute][:results] == [%{doubled: 20.0}, %{doubled: 40.0}]
    end
  end

  describe "MapNode with empty list" do
    test "empty items flows through without error" do
      agent = EmptyMapWorkflow.new()

      assert {:ok, result} = EmptyMapWorkflow.run_sync(agent, %{})

      assert result[:process][:results] == []
    end
  end

  describe "MapNode element failure" do
    test "element failure triggers error transition" do
      agent = FailingMapWorkflow.new()
      {agent, directives} = FailingMapWorkflow.run(agent, %{items: [%{}, %{}]})

      agent = execute_workflow(FailingMapWorkflow, agent, directives)

      strat = StratState.get(agent)
      assert strat.machine.status == :failed
      assert StratState.status(agent) == :failure
    end
  end

  describe "context propagation" do
    test "prior step results visible in element context via list path" do
      agent = MapWorkflow.new()
      {agent, directives} = MapWorkflow.run(agent, %{})

      # After generate step, items should be accessible at [:generate, :items]
      agent = execute_workflow(MapWorkflow, agent, directives)

      strat = StratState.get(agent)
      ctx = strat.machine.context.working

      # generate step produced items
      assert is_list(ctx[:generate][:items])
      # process step mapped over them
      assert is_list(ctx[:process][:results])
      # aggregate consumed the mapped results
      assert ctx[:aggregate][:total] == 12.0
    end
  end

  describe "MapNode emits correct directives" do
    test "strategy recognizes MapNode and emits FanOutBranch directives" do
      agent = SingleMapWorkflow.new()

      {agent, directives} =
        SingleMapWorkflow.run(agent, %{items: [%{value: 1.0}, %{value: 2.0}]})

      assert length(directives) == 2
      assert Enum.all?(directives, &match?(%FanOutBranch{}, &1))

      strat = StratState.get(agent)
      assert strat.fan_out != nil
      assert strat.fan_out.merge == :ordered_list
    end

    test "empty list emits RunInstruction for EmptyResult" do
      agent = EmptyMapWorkflow.new()

      {_agent, directives} = EmptyMapWorkflow.run(agent, %{})

      assert length(directives) == 1
      assert [%Directive.RunInstruction{} = directive] = directives
      assert directive.instruction.action == MapNode.EmptyResult
    end
  end
end
