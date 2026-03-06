defmodule Jido.Composer.Workflow.MachineTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.Workflow.Machine
  alias Jido.Composer.Node.ActionNode
  alias Jido.Composer.NodeIO
  alias Jido.Composer.TestActions.{AddAction, MultiplyAction, FailAction}

  defp build_nodes do
    {:ok, extract} = ActionNode.new(AddAction)
    {:ok, transform} = ActionNode.new(MultiplyAction)
    {:ok, fail_node} = ActionNode.new(FailAction)
    %{extract: extract, transform: transform, fail_node: fail_node}
  end

  defp linear_machine do
    nodes = build_nodes()

    Machine.new(
      nodes: %{extract: nodes.extract, transform: nodes.transform},
      transitions: %{
        {:extract, :ok} => :transform,
        {:transform, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :extract
    )
  end

  describe "new/1" do
    test "creates a machine with initial state" do
      machine = linear_machine()
      assert machine.status == :extract
    end

    test "defaults terminal states to :done and :failed" do
      machine = linear_machine()
      assert :done in machine.terminal_states
      assert :failed in machine.terminal_states
    end

    test "accepts custom terminal states" do
      nodes = build_nodes()

      machine =
        Machine.new(
          nodes: %{extract: nodes.extract},
          transitions: %{{:extract, :ok} => :completed},
          initial: :extract,
          terminal_states: [:completed, :aborted]
        )

      assert :completed in machine.terminal_states
      assert :aborted in machine.terminal_states
    end

    test "initializes with empty context" do
      machine = linear_machine()
      assert machine.context == %{}
    end

    test "initializes with empty history" do
      machine = linear_machine()
      assert machine.history == []
    end

    test "accepts initial context" do
      nodes = build_nodes()

      machine =
        Machine.new(
          nodes: %{extract: nodes.extract},
          transitions: %{{:extract, :ok} => :done},
          initial: :extract,
          context: %{input: "data"}
        )

      assert machine.context == %{input: "data"}
    end
  end

  describe "current_node/1" do
    test "returns the node bound to the current state" do
      machine = linear_machine()
      node = Machine.current_node(machine)
      assert %ActionNode{} = node
      assert ActionNode.name(node) == "add"
    end

    test "returns nil for terminal states" do
      machine = linear_machine()
      machine = %{machine | status: :done}
      assert Machine.current_node(machine) == nil
    end
  end

  describe "terminal?/1" do
    test "returns false for non-terminal states" do
      machine = linear_machine()
      refute Machine.terminal?(machine)
    end

    test "returns true for :done state" do
      machine = %{linear_machine() | status: :done}
      assert Machine.terminal?(machine)
    end

    test "returns true for :failed state" do
      machine = %{linear_machine() | status: :failed}
      assert Machine.terminal?(machine)
    end
  end

  describe "transition/2" do
    test "exact match transition" do
      machine = linear_machine()
      assert {:ok, machine} = Machine.transition(machine, :ok)
      assert machine.status == :transform
    end

    test "wildcard state fallback" do
      machine = linear_machine()
      assert {:ok, machine} = Machine.transition(machine, :error)
      assert machine.status == :failed
    end

    test "wildcard outcome fallback" do
      nodes = build_nodes()

      machine =
        Machine.new(
          nodes: %{start: nodes.extract},
          transitions: %{{:start, :_} => :done},
          initial: :start
        )

      assert {:ok, machine} = Machine.transition(machine, :whatever)
      assert machine.status == :done
    end

    test "global fallback {:_, :_}" do
      nodes = build_nodes()

      machine =
        Machine.new(
          nodes: %{start: nodes.extract},
          transitions: %{{:_, :_} => :done},
          initial: :start
        )

      assert {:ok, machine} = Machine.transition(machine, :anything)
      assert machine.status == :done
    end

    test "returns error when no transition found" do
      nodes = build_nodes()

      machine =
        Machine.new(
          nodes: %{start: nodes.extract},
          transitions: %{{:start, :ok} => :done},
          initial: :start
        )

      assert {:error, _reason} = Machine.transition(machine, :unexpected)
    end

    test "records transition in history" do
      machine = linear_machine()
      assert {:ok, machine} = Machine.transition(machine, :ok)
      assert [{:extract, :ok, _timestamp}] = machine.history
    end

    test "multiple transitions build history" do
      machine = linear_machine()
      {:ok, machine} = Machine.transition(machine, :ok)
      {:ok, machine} = Machine.transition(machine, :ok)
      assert length(machine.history) == 2
      assert [{:transform, :ok, _}, {:extract, :ok, _}] = machine.history
    end
  end

  describe "apply_result/2" do
    test "scopes result under state name and deep merges" do
      machine = linear_machine()
      result = %{records: [1, 2, 3]}

      machine = Machine.apply_result(machine, result)
      assert machine.context == %{extract: %{records: [1, 2, 3]}}
    end

    test "preserves existing context from other states" do
      machine = linear_machine()
      machine = Machine.apply_result(machine, %{records: [1, 2, 3]})
      {:ok, machine} = Machine.transition(machine, :ok)
      machine = Machine.apply_result(machine, %{cleaned: [1, 2]})

      assert machine.context.extract == %{records: [1, 2, 3]}
      assert machine.context.transform == %{cleaned: [1, 2]}
    end

    test "deep merges nested maps within same scope" do
      machine = linear_machine()
      machine = Machine.apply_result(machine, %{a: %{x: 1}})

      # Simulate re-running same state with additional nested data
      machine = Machine.apply_result(machine, %{a: %{y: 2}})

      assert machine.context.extract.a == %{x: 1, y: 2}
    end

    test "resolves NodeIO.text to map" do
      machine = linear_machine()
      machine = Machine.apply_result(machine, NodeIO.text("answer"))
      assert machine.context == %{extract: %{text: "answer"}}
    end

    test "resolves NodeIO.object to map" do
      machine = linear_machine()
      machine = Machine.apply_result(machine, NodeIO.object(%{score: 0.9}))
      assert machine.context == %{extract: %{object: %{score: 0.9}}}
    end

    test "passes through bare maps unchanged" do
      machine = linear_machine()
      machine = Machine.apply_result(machine, %{key: "value"})
      assert machine.context == %{extract: %{key: "value"}}
    end

    test "resolves NodeIO.map to map" do
      machine = linear_machine()
      machine = Machine.apply_result(machine, NodeIO.map(%{key: "value"}))
      assert machine.context == %{extract: %{key: "value"}}
    end
  end
end
