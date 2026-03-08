defmodule Jido.Composer.ToolConcurrencyTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.ToolConcurrency

  describe "new/1" do
    test "creates default state with no concurrency limit" do
      tc = ToolConcurrency.new()
      assert tc.pending == []
      assert tc.completed == []
      assert tc.queued == []
      assert tc.max_concurrency == nil
    end

    test "creates state with concurrency limit" do
      tc = ToolConcurrency.new(max_concurrency: 2)
      assert tc.max_concurrency == 2
    end
  end

  describe "split_for_dispatch/2" do
    test "dispatches all when no concurrency limit" do
      tc = ToolConcurrency.new()
      calls = [%{id: "a"}, %{id: "b"}, %{id: "c"}]
      {to_dispatch, to_queue} = ToolConcurrency.split_for_dispatch(tc, calls)
      assert to_dispatch == calls
      assert to_queue == []
    end

    test "splits when calls exceed limit" do
      tc = ToolConcurrency.new(max_concurrency: 2)
      calls = [%{id: "a"}, %{id: "b"}, %{id: "c"}]
      {to_dispatch, to_queue} = ToolConcurrency.split_for_dispatch(tc, calls)
      assert length(to_dispatch) == 2
      assert length(to_queue) == 1
    end

    test "dispatches all when under limit" do
      tc = ToolConcurrency.new(max_concurrency: 5)
      calls = [%{id: "a"}, %{id: "b"}]
      {to_dispatch, to_queue} = ToolConcurrency.split_for_dispatch(tc, calls)
      assert to_dispatch == calls
      assert to_queue == []
    end
  end

  describe "dispatch/3" do
    test "sets pending and queued, resets completed" do
      tc = ToolConcurrency.new() |> Map.put(:completed, [%{old: true}])
      tc = ToolConcurrency.dispatch(tc, ["a", "b"], [%{id: "c"}])
      assert tc.pending == ["a", "b"]
      assert tc.completed == []
      assert tc.queued == [%{id: "c"}]
    end
  end

  describe "record_result/3" do
    test "removes from pending and appends to completed" do
      tc = ToolConcurrency.dispatch(ToolConcurrency.new(), ["a", "b"], [])
      tc = ToolConcurrency.record_result(tc, "a", %{result: "done"})
      assert tc.pending == ["b"]
      assert tc.completed == [%{result: "done"}]
    end
  end

  describe "add_pending/2" do
    test "appends call ID to pending" do
      tc = ToolConcurrency.dispatch(ToolConcurrency.new(), ["a"], [])
      tc = ToolConcurrency.add_pending(tc, "b")
      assert tc.pending == ["a", "b"]
    end
  end

  describe "enqueue/2" do
    test "appends call to queued" do
      tc = ToolConcurrency.new()
      assert {:ok, tc} = ToolConcurrency.enqueue(tc, %{id: "x"})
      assert tc.queued == [%{id: "x"}]
    end

    test "returns error when queue is full" do
      tc = ToolConcurrency.new(max_queue_depth: 2)
      assert {:ok, tc} = ToolConcurrency.enqueue(tc, %{id: "a"})
      assert {:ok, tc} = ToolConcurrency.enqueue(tc, %{id: "b"})
      assert {:error, :queue_full} = ToolConcurrency.enqueue(tc, %{id: "c"})
    end

    test "allows enqueue when no max_queue_depth" do
      tc = ToolConcurrency.new()
      assert {:ok, tc} = ToolConcurrency.enqueue(tc, %{id: "a"})
      assert {:ok, tc} = ToolConcurrency.enqueue(tc, %{id: "b"})
      assert {:ok, _tc} = ToolConcurrency.enqueue(tc, %{id: "c"})
    end
  end

  describe "at_capacity?/1" do
    test "false when no limit" do
      tc = ToolConcurrency.dispatch(ToolConcurrency.new(), ["a", "b", "c"], [])
      refute ToolConcurrency.at_capacity?(tc)
    end

    test "true when at limit" do
      tc = ToolConcurrency.new(max_concurrency: 2)
      tc = ToolConcurrency.dispatch(tc, ["a", "b"], [])
      assert ToolConcurrency.at_capacity?(tc)
    end

    test "false when under limit" do
      tc = ToolConcurrency.new(max_concurrency: 3)
      tc = ToolConcurrency.dispatch(tc, ["a"], [])
      refute ToolConcurrency.at_capacity?(tc)
    end
  end

  describe "drain_queue/1" do
    test "returns empty when no queued calls" do
      tc = ToolConcurrency.new()
      {tc, dispatched} = ToolConcurrency.drain_queue(tc)
      assert dispatched == []
      assert tc.queued == []
    end

    test "dispatches queued calls when slots available" do
      tc = ToolConcurrency.new(max_concurrency: 2)
      tc = ToolConcurrency.dispatch(tc, ["a"], [%{id: "b"}, %{id: "c"}])
      # One slot available (max 2, 1 pending)
      {tc, dispatched} = ToolConcurrency.drain_queue(tc)
      assert length(dispatched) == 1
      assert [%{id: "b"}] = dispatched
      assert tc.pending == ["a", "b"]
      assert tc.queued == [%{id: "c"}]
    end

    test "dispatches nothing when at capacity" do
      tc = ToolConcurrency.new(max_concurrency: 1)
      tc = ToolConcurrency.dispatch(tc, ["a"], [%{id: "b"}])
      {tc, dispatched} = ToolConcurrency.drain_queue(tc)
      assert dispatched == []
      assert tc.queued == [%{id: "b"}]
    end

    test "dispatches all queued when unlimited" do
      tc = ToolConcurrency.new()
      tc = %{tc | queued: [%{id: "a"}, %{id: "b"}]}
      {tc, dispatched} = ToolConcurrency.drain_queue(tc)
      assert length(dispatched) == 2
      assert tc.queued == []
      assert tc.pending == ["a", "b"]
    end
  end

  describe "all_clear?/1" do
    test "true when nothing pending or queued" do
      assert ToolConcurrency.all_clear?(ToolConcurrency.new())
    end

    test "false when pending" do
      tc = ToolConcurrency.dispatch(ToolConcurrency.new(), ["a"], [])
      refute ToolConcurrency.all_clear?(tc)
    end

    test "false when queued" do
      tc = %{ToolConcurrency.new() | queued: [%{id: "a"}]}
      refute ToolConcurrency.all_clear?(tc)
    end
  end

  describe "has_pending?/1" do
    test "false when no pending" do
      refute ToolConcurrency.has_pending?(ToolConcurrency.new())
    end

    test "true when pending" do
      tc = ToolConcurrency.dispatch(ToolConcurrency.new(), ["a"], [])
      assert ToolConcurrency.has_pending?(tc)
    end
  end

  describe "serialization" do
    test "survives term_to_binary round-trip" do
      tc = ToolConcurrency.new(max_concurrency: 3)
      tc = ToolConcurrency.dispatch(tc, ["a", "b"], [%{id: "c"}])
      tc = ToolConcurrency.record_result(tc, "a", %{result: "done"})

      binary = :erlang.term_to_binary(tc, [:compressed])
      restored = :erlang.binary_to_term(binary)

      assert %ToolConcurrency{} = restored
      assert restored.pending == ["b"]
      assert restored.completed == [%{result: "done"}]
      assert restored.queued == [%{id: "c"}]
      assert restored.max_concurrency == 3
    end
  end
end
