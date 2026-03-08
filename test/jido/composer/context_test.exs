defmodule Jido.Composer.ContextTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.Context

  defmodule TestForks do
    def depth_fork(ambient, _working) do
      Map.update(ambient, :depth, 1, &(&1 + 1))
    end

    def correlation_fork(ambient, _working) do
      parent_id = ambient[:correlation_id] || "root"
      Map.put(ambient, :correlation_id, "#{parent_id}/child")
    end

    def summary_fork(ambient, working) do
      Map.put(ambient, :parent_steps, map_size(working))
    end
  end

  describe "new/1" do
    test "creates empty context with no args" do
      ctx = Context.new()
      assert ctx.ambient == %{}
      assert ctx.working == %{}
      assert ctx.fork_fns == %{}
    end

    test "creates context with all fields" do
      ctx =
        Context.new(
          ambient: %{org_id: "acme"},
          working: %{data: 1},
          fork_fns: %{depth: {TestForks, :depth_fork, []}}
        )

      assert ctx.ambient == %{org_id: "acme"}
      assert ctx.working == %{data: 1}
      assert ctx.fork_fns == %{depth: {TestForks, :depth_fork, []}}
    end
  end

  describe "get_ambient/2" do
    test "returns ambient value by key" do
      ctx = Context.new(ambient: %{org_id: "acme", user_id: "alice"})
      assert Context.get_ambient(ctx, :org_id) == "acme"
      assert Context.get_ambient(ctx, :user_id) == "alice"
    end

    test "returns nil for missing key" do
      ctx = Context.new(ambient: %{org_id: "acme"})
      assert Context.get_ambient(ctx, :missing) == nil
    end
  end

  describe "apply_result/3" do
    test "scopes result in working under the given scope" do
      ctx = Context.new()
      ctx = Context.apply_result(ctx, :step1, %{value: 42})
      assert ctx.working == %{step1: %{value: 42}}
    end

    test "does not modify ambient" do
      ctx = Context.new(ambient: %{org_id: "acme"})
      ctx = Context.apply_result(ctx, :step1, %{value: 42})
      assert ctx.ambient == %{org_id: "acme"}
    end

    test "deep merges within working" do
      ctx = Context.new(working: %{step1: %{a: 1}})
      ctx = Context.apply_result(ctx, :step1, %{b: 2})
      assert ctx.working == %{step1: %{a: 1, b: 2}}
    end

    test "preserves other scopes when adding new" do
      ctx = Context.new()
      ctx = Context.apply_result(ctx, :step1, %{records: [1, 2]})
      ctx = Context.apply_result(ctx, :step2, %{cleaned: [1]})
      assert ctx.working[:step1] == %{records: [1, 2]}
      assert ctx.working[:step2] == %{cleaned: [1]}
    end
  end

  describe "fork_for_child/1" do
    test "runs MFA fork functions on ambient" do
      ctx =
        Context.new(
          ambient: %{depth: 0},
          fork_fns: %{depth: {TestForks, :depth_fork, []}}
        )

      forked = Context.fork_for_child(ctx)
      assert forked.ambient[:depth] == 1
    end

    test "composes multiple fork functions" do
      ctx =
        Context.new(
          ambient: %{depth: 0, correlation_id: "root"},
          working: %{step1: %{done: true}},
          fork_fns: %{
            depth: {TestForks, :depth_fork, []},
            correlation: {TestForks, :correlation_fork, []},
            summary: {TestForks, :summary_fork, []}
          }
        )

      forked = Context.fork_for_child(ctx)
      assert forked.ambient[:depth] == 1
      assert forked.ambient[:correlation_id] == "root/child"
      assert forked.ambient[:parent_steps] == 1
    end

    test "does not modify working" do
      ctx =
        Context.new(
          ambient: %{depth: 0},
          working: %{data: "original"},
          fork_fns: %{depth: {TestForks, :depth_fork, []}}
        )

      forked = Context.fork_for_child(ctx)
      assert forked.working == %{data: "original"}
    end

    test "with no fork functions returns context unchanged" do
      ctx = Context.new(ambient: %{org_id: "acme"})
      forked = Context.fork_for_child(ctx)
      assert forked.ambient == %{org_id: "acme"}
    end

    test "raises ArgumentError when fork function returns a non-map" do
      defmodule BadFork do
        def bad_fork(_ambient, _working), do: :not_a_map
      end

      ctx =
        Context.new(
          ambient: %{org_id: "acme"},
          fork_fns: %{bad: {BadFork, :bad_fork, []}}
        )

      assert_raise ArgumentError, ~r/must return a map/, fn ->
        Context.fork_for_child(ctx)
      end
    end
  end

  describe "to_flat_map/1" do
    test "puts ambient under ambient_key in working" do
      ctx = Context.new(ambient: %{org_id: "acme"}, working: %{data: 1})
      flat = Context.to_flat_map(ctx)
      assert flat == Map.put(%{data: 1}, Context.ambient_key(), %{org_id: "acme"})
    end

    test "empty ambient produces empty ambient_key map" do
      ctx = Context.new(working: %{data: 1})
      flat = Context.to_flat_map(ctx)
      assert flat == Map.put(%{data: 1}, Context.ambient_key(), %{})
    end
  end

  describe "to_serializable/1 and from_serializable/1" do
    test "round-trip preserves all fields" do
      ctx =
        Context.new(
          ambient: %{org_id: "acme", trace_id: "xyz"},
          working: %{step1: %{records: [1, 2]}},
          fork_fns: %{
            depth: {TestForks, :depth_fork, []},
            correlation: {TestForks, :correlation_fork, []}
          }
        )

      serialized = Context.to_serializable(ctx)
      restored = Context.from_serializable(serialized)

      assert restored.ambient == ctx.ambient
      assert restored.working == ctx.working
      assert restored.fork_fns == ctx.fork_fns
    end

    test "serializable form survives :erlang.term_to_binary round-trip" do
      ctx =
        Context.new(
          ambient: %{org_id: "acme"},
          fork_fns: %{depth: {TestForks, :depth_fork, []}}
        )

      binary = ctx |> Context.to_serializable() |> :erlang.term_to_binary()
      restored = binary |> :erlang.binary_to_term() |> Context.from_serializable()

      # Fork functions still work after restore
      forked = Context.fork_for_child(restored)
      assert forked.ambient[:depth] == 1
    end
  end

  describe "backward compatibility" do
    test "bare map can be wrapped into Context" do
      # This is what Machine.new should do
      bare_map = %{input: "data", value: 42}
      ctx = Context.new(working: bare_map)

      assert ctx.working == bare_map
      assert ctx.ambient == %{}
      assert ctx.fork_fns == %{}
    end
  end
end
