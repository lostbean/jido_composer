defmodule Jido.Composer.FanOut.StateTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.FanOut.State, as: FanOutState
  alias Jido.Composer.Node.{ActionNode, FanOutNode}
  alias Jido.Composer.Suspension
  alias Jido.Composer.TestActions.{AddAction, EchoAction}

  defp make_fan_out_state(opts \\ []) do
    {:ok, add_node} = ActionNode.new(AddAction)
    {:ok, echo_node} = ActionNode.new(EchoAction)

    {:ok, fan_out_node} =
      FanOutNode.new(
        name: "test_fan_out",
        branches: [add: add_node, echo: echo_node],
        max_concurrency: Keyword.get(opts, :max_concurrency)
      )

    dispatched = MapSet.new(Keyword.get(opts, :dispatched, [:add, :echo]))
    queued = Keyword.get(opts, :queued, [])

    FanOutState.new("fan-out-1", fan_out_node, dispatched, queued)
  end

  describe "new/4" do
    test "creates state from fan_out_node" do
      state = make_fan_out_state()
      assert state.id == "fan-out-1"
      assert MapSet.size(state.pending_branches) == 2
      assert state.completed_results == %{}
      assert state.suspended_branches == %{}
      assert state.queued_branches == []
    end
  end

  describe "branch_completed/3" do
    test "moves branch from pending to completed" do
      state = make_fan_out_state() |> FanOutState.branch_completed(:add, %{result: 3.0})

      assert state.completed_results[:add] == %{result: 3.0}
      refute MapSet.member?(state.pending_branches, :add)
      assert MapSet.member?(state.pending_branches, :echo)
    end
  end

  describe "branch_suspended/4" do
    test "moves branch from pending to suspended" do
      {:ok, suspension} = Suspension.new(reason: :rate_limit)

      state =
        make_fan_out_state()
        |> FanOutState.branch_suspended(:add, suspension, %{partial: true})

      refute MapSet.member?(state.pending_branches, :add)
      assert Map.has_key?(state.suspended_branches, :add)
      assert state.suspended_branches[:add].suspension == suspension
      assert state.suspended_branches[:add].partial_result == %{partial: true}
    end
  end

  describe "branch_error/3" do
    test "records error in completed results" do
      state = make_fan_out_state() |> FanOutState.branch_error(:add, :timeout)

      assert state.completed_results[:add] == {:error, :timeout}
      refute MapSet.member?(state.pending_branches, :add)
    end
  end

  describe "drain_queue/1" do
    test "returns empty when no queued branches" do
      state = make_fan_out_state()
      {state, dispatched} = FanOutState.drain_queue(state)
      assert dispatched == []
      assert state.queued_branches == []
    end

    test "dispatches queued branches when slots available" do
      state =
        make_fan_out_state(
          max_concurrency: 1,
          dispatched: [:add],
          queued: [{:echo, :some_directive}]
        )

      # Complete the add branch to free a slot
      state = FanOutState.branch_completed(state, :add, %{result: 3.0})
      {state, dispatched} = FanOutState.drain_queue(state)

      assert length(dispatched) == 1
      assert [{:echo, :some_directive}] = dispatched
      assert MapSet.member?(state.pending_branches, :echo)
      assert state.queued_branches == []
    end
  end

  describe "completion_status/1" do
    test "returns :all_done when everything completed" do
      state =
        make_fan_out_state()
        |> FanOutState.branch_completed(:add, %{r: 1})
        |> FanOutState.branch_completed(:echo, %{r: 2})

      assert FanOutState.completion_status(state) == :all_done
    end

    test "returns :suspended when suspensions remain" do
      {:ok, sus} = Suspension.new(reason: :rate_limit)

      state =
        make_fan_out_state()
        |> FanOutState.branch_completed(:echo, %{r: 1})
        |> FanOutState.branch_suspended(:add, sus, nil)

      assert FanOutState.completion_status(state) == :suspended
    end

    test "returns :in_progress when branches still pending" do
      state = make_fan_out_state() |> FanOutState.branch_completed(:add, %{r: 1})
      assert FanOutState.completion_status(state) == :in_progress
    end
  end

  describe "has_suspended_branch?/2" do
    test "returns true when suspension matches" do
      {:ok, sus} = Suspension.new(reason: :rate_limit)
      state = make_fan_out_state() |> FanOutState.branch_suspended(:add, sus, nil)
      assert FanOutState.has_suspended_branch?(state, sus.id)
    end

    test "returns false when no match" do
      state = make_fan_out_state()
      refute FanOutState.has_suspended_branch?(state, "nonexistent")
    end
  end

  describe "find_suspended_branch/2" do
    test "finds branch by suspension_id" do
      {:ok, sus} = Suspension.new(reason: :rate_limit)
      state = make_fan_out_state() |> FanOutState.branch_suspended(:add, sus, nil)
      assert {:add, %{suspension: ^sus}} = FanOutState.find_suspended_branch(state, sus.id)
    end

    test "returns nil when not found" do
      state = make_fan_out_state()
      assert FanOutState.find_suspended_branch(state, "nonexistent") == nil
    end
  end

  describe "resume_branch/2" do
    test "removes branch from suspended" do
      {:ok, sus} = Suspension.new(reason: :rate_limit)

      state =
        make_fan_out_state()
        |> FanOutState.branch_suspended(:add, sus, nil)
        |> FanOutState.resume_branch(:add)

      assert state.suspended_branches == %{}
    end
  end

  describe "merge_results/1" do
    test "merges with deep_merge strategy" do
      state =
        make_fan_out_state()
        |> FanOutState.branch_completed(:add, %{result: 3.0})
        |> FanOutState.branch_completed(:echo, %{echoed: "hi"})

      merged = FanOutState.merge_results(state)
      assert merged[:add][:result] == 3.0
      assert merged[:echo][:echoed] == "hi"
    end

    test "merges with :ordered_list strategy" do
      state =
        make_fan_out_state()
        |> Map.put(:merge, :ordered_list)
        |> FanOutState.branch_completed(:item_0, %{doubled: 2})
        |> FanOutState.branch_completed(:item_1, %{doubled: 4})
        |> FanOutState.branch_completed(:item_2, %{doubled: 6})

      merged = FanOutState.merge_results(state)
      assert merged == %{results: [%{doubled: 2}, %{doubled: 4}, %{doubled: 6}]}
    end

    test ":ordered_list sorts by item index" do
      state =
        make_fan_out_state()
        |> Map.put(:merge, :ordered_list)
        |> FanOutState.branch_completed(:item_2, %{v: 3})
        |> FanOutState.branch_completed(:item_0, %{v: 1})
        |> FanOutState.branch_completed(:item_1, %{v: 2})

      merged = FanOutState.merge_results(state)
      assert merged == %{results: [%{v: 1}, %{v: 2}, %{v: 3}]}
    end
  end

  describe "total_branches" do
    test "is computed from node branches" do
      state = make_fan_out_state()
      assert state.total_branches == 2
    end
  end

  describe "serialization" do
    test "survives term_to_binary round-trip" do
      state = make_fan_out_state()
      binary = :erlang.term_to_binary(state, [:compressed])
      restored = :erlang.binary_to_term(binary)
      assert %FanOutState{} = restored
      assert restored.id == "fan-out-1"
    end
  end
end
