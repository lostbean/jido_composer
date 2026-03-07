defmodule Jido.Composer.CheckpointTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.Checkpoint
  alias Jido.Composer.Context

  describe "prepare_for_checkpoint/1" do
    test "strips closures (approval_policy → nil)" do
      strategy_state = %{
        module: Jido.Composer.Orchestrator.Strategy,
        status: :awaiting_approval,
        approval_policy: fn _call, _ctx -> :require_approval end,
        nodes: %{"echo" => %{name: "echo"}},
        conversation: [%{role: "user", content: "hello"}],
        context: %{foo: "bar"}
      }

      cleaned = Checkpoint.prepare_for_checkpoint(strategy_state)
      assert cleaned.approval_policy == nil
      assert cleaned.status == :awaiting_approval
      assert cleaned.nodes == %{"echo" => %{name: "echo"}}
      assert cleaned.conversation == [%{role: "user", content: "hello"}]
    end

    test "preserves serializable state" do
      machine = %{
        status: :approval,
        context: Context.new(working: %{tag: "test"}),
        nodes: %{},
        transitions: %{},
        terminal_states: MapSet.new([:done, :failed]),
        history: [{:process, :ok, 12_345}]
      }

      strategy_state = %{
        module: Jido.Composer.Workflow.Strategy,
        status: :waiting,
        machine: machine,
        pending_suspension: %{id: "suspend-abc", reason: :human_input},
        pending_fan_out: nil,
        pending_child: nil,
        child_request_id: nil,
        ambient_keys: [:tenant_id],
        fork_fns: %{}
      }

      cleaned = Checkpoint.prepare_for_checkpoint(strategy_state)

      assert cleaned.machine.status == :approval
      assert cleaned.pending_suspension.id == "suspend-abc"
      assert cleaned.ambient_keys == [:tenant_id]

      # Must be fully serializable
      binary = :erlang.term_to_binary(cleaned, [:compressed])
      restored = :erlang.binary_to_term(binary)
      assert restored.machine.status == :approval
    end

    test "strips any closure values at top level" do
      strategy_state = %{
        module: Jido.Composer.Orchestrator.Strategy,
        status: :running,
        approval_policy: &is_atom/1,
        some_other_fn: fn -> :nope end,
        data: "keep me"
      }

      cleaned = Checkpoint.prepare_for_checkpoint(strategy_state)
      assert cleaned.approval_policy == nil
      assert cleaned.some_other_fn == nil
      assert cleaned.data == "keep me"
    end
  end

  describe "reattach_runtime_config/2" do
    test "restores closures from strategy_opts" do
      policy_fn = fn _call, _ctx -> :require_approval end

      strategy_opts = [
        approval_policy: policy_fn,
        nodes: [SomeModule],
        model: "test-model"
      ]

      checkpoint_state = %{
        module: Jido.Composer.Orchestrator.Strategy,
        status: :awaiting_approval,
        approval_policy: nil,
        nodes: %{},
        context: %{}
      }

      restored = Checkpoint.reattach_runtime_config(checkpoint_state, strategy_opts)
      assert restored.approval_policy == policy_fn
    end

    test "does not overwrite existing non-nil values" do
      existing_fn = fn _call, _ctx -> :existing end
      new_fn = fn _call, _ctx -> :new end

      strategy_opts = [approval_policy: new_fn]

      checkpoint_state = %{
        approval_policy: existing_fn,
        status: :running
      }

      restored = Checkpoint.reattach_runtime_config(checkpoint_state, strategy_opts)
      # The existing non-nil value should be preserved
      assert restored.approval_policy == existing_fn
    end

    test "restores nil closures from strategy_opts" do
      policy_fn = fn _call, _ctx -> :ok end

      strategy_opts = [approval_policy: policy_fn]
      checkpoint_state = %{approval_policy: nil, status: :waiting}

      restored = Checkpoint.reattach_runtime_config(checkpoint_state, strategy_opts)
      assert restored.approval_policy == policy_fn
    end
  end

  describe "migrate/2" do
    test "v1 → v2 adds :children field" do
      v1_state = %{
        module: Jido.Composer.Workflow.Strategy,
        status: :running,
        machine: %{status: :process}
      }

      migrated = Checkpoint.migrate(v1_state, 1)
      assert migrated.children == %{}
      # Original fields preserved
      assert migrated.module == Jido.Composer.Workflow.Strategy
      assert migrated.status == :running
      assert migrated.machine == %{status: :process}
    end

    test "v1 → v2 does not overwrite existing :children" do
      v1_state = %{
        status: :running,
        children: %{child1: :ref}
      }

      migrated = Checkpoint.migrate(v1_state, 1)
      assert migrated.children == %{child1: :ref}
    end

    test "v2 migrates to v3 (adds checkpoint_status and child_phases)" do
      v2_state = %{
        status: :running,
        children: %{},
        machine: %{status: :done}
      }

      migrated = Checkpoint.migrate(v2_state, 2)
      assert migrated.checkpoint_status == :hibernated
      assert migrated.child_phases == %{}
      assert migrated.children == %{}
    end
  end

  describe "checkpoint schema version" do
    test "checkpoint schema version is :composer_v4" do
      assert Checkpoint.schema_version() == :composer_v4
    end
  end

  describe "transition_status/2" do
    test "hibernated -> resuming is valid" do
      assert :ok = Checkpoint.transition_status(:hibernated, :resuming)
    end

    test "resuming -> resumed is valid" do
      assert :ok = Checkpoint.transition_status(:resuming, :resumed)
    end

    test "resumed -> resuming is invalid" do
      assert {:error, {:invalid_transition, :resumed, :resuming}} =
               Checkpoint.transition_status(:resumed, :resuming)
    end

    test "hibernated -> resumed is invalid (must go through resuming)" do
      assert {:error, {:invalid_transition, :hibernated, :resumed}} =
               Checkpoint.transition_status(:hibernated, :resumed)
    end

    test "unknown status returns error" do
      assert {:error, {:invalid_transition, :bogus, :resuming}} =
               Checkpoint.transition_status(:bogus, :resuming)
    end
  end

  describe "prepare_for_checkpoint/1 sets checkpoint_status" do
    test "adds checkpoint_status :hibernated" do
      strategy_state = %{
        module: Jido.Composer.Workflow.Strategy,
        status: :waiting,
        machine: %{status: :process}
      }

      cleaned = Checkpoint.prepare_for_checkpoint(strategy_state)
      assert cleaned.checkpoint_status == :hibernated
    end

    test "does not overwrite existing checkpoint_status" do
      strategy_state = %{
        module: Jido.Composer.Workflow.Strategy,
        status: :waiting,
        checkpoint_status: :resuming
      }

      cleaned = Checkpoint.prepare_for_checkpoint(strategy_state)
      assert cleaned.checkpoint_status == :resuming
    end
  end

  describe "migrate/2 v2 -> v3" do
    test "adds checkpoint_status and child_phases defaults" do
      v2_state = %{
        module: Jido.Composer.Workflow.Strategy,
        status: :running,
        children: %{}
      }

      migrated = Checkpoint.migrate(v2_state, 2)
      assert migrated.checkpoint_status == :hibernated
      assert migrated.child_phases == %{}
    end

    test "v2 -> v3 does not overwrite existing fields" do
      v2_state = %{
        status: :running,
        children: %{child1: :ref},
        checkpoint_status: :resuming,
        child_phases: %{child1: :awaiting_result}
      }

      migrated = Checkpoint.migrate(v2_state, 2)
      assert migrated.checkpoint_status == :resuming
      assert migrated.child_phases == %{child1: :awaiting_result}
    end

    test "v1 -> v3 migration chain adds all fields" do
      v1_state = %{
        module: Jido.Composer.Workflow.Strategy,
        status: :running
      }

      migrated = Checkpoint.migrate(v1_state, 1)
      assert migrated.children == %{}
      assert migrated.checkpoint_status == :hibernated
      assert migrated.child_phases == %{}
    end

    test "v3 migrates generation_mode to stream" do
      v3_state = %{
        status: :running,
        children: %{},
        checkpoint_status: :hibernated,
        child_phases: %{},
        generation_mode: :stream_text
      }

      migrated = Checkpoint.migrate(v3_state, 3)
      assert migrated.stream == true
      refute Map.has_key?(migrated, :generation_mode)
    end

    test "v3 defaults stream to false for non-streaming generation_mode" do
      v3_state = %{
        status: :running,
        children: %{},
        checkpoint_status: :hibernated,
        child_phases: %{},
        generation_mode: :generate_text
      }

      migrated = Checkpoint.migrate(v3_state, 3)
      assert migrated.stream == false
      refute Map.has_key?(migrated, :generation_mode)
    end

    test "v4 is a no-op for current version" do
      v4_state = %{
        status: :running,
        children: %{},
        checkpoint_status: :hibernated,
        child_phases: %{},
        stream: false
      }

      assert Checkpoint.migrate(v4_state, 4) == v4_state
    end
  end

  describe "pending_child_respawns/1" do
    alias Jido.Composer.ChildRef

    test "returns SpawnAgent directives for paused children" do
      strategy_state = %{
        children: %{
          worker: %ChildRef{
            agent_module: SomeModule,
            agent_id: "child-1",
            tag: :worker,
            status: :paused,
            checkpoint_key: "ck-worker"
          },
          done: %ChildRef{
            agent_module: OtherModule,
            agent_id: "child-2",
            tag: :done,
            status: :completed
          }
        }
      }

      directives = Checkpoint.pending_child_respawns(strategy_state)
      assert length(directives) == 1

      [spawn] = directives
      assert spawn.__struct__ == Jido.Agent.Directive.SpawnAgent
      assert spawn.agent == SomeModule
      assert spawn.tag == :worker
      assert spawn.opts.id == "child-1"
      assert spawn.opts.checkpoint_key == "ck-worker"
    end

    test "returns empty list when no paused children" do
      strategy_state = %{
        children: %{
          worker: %ChildRef{
            agent_module: SomeModule,
            agent_id: "child-1",
            tag: :worker,
            status: :running
          }
        }
      }

      assert Checkpoint.pending_child_respawns(strategy_state) == []
    end

    test "returns empty list when children map is empty" do
      assert Checkpoint.pending_child_respawns(%{children: %{}}) == []
    end

    test "returns empty list when children key is missing" do
      assert Checkpoint.pending_child_respawns(%{}) == []
    end
  end

  describe "replay_directives/1" do
    alias Jido.Composer.ChildRef

    test "replays SpawnAgent for child in :spawning phase" do
      strategy_state = %{
        child_phases: %{worker: :spawning},
        children: %{
          worker: %ChildRef{
            agent_module: SomeModule,
            agent_id: "child-spawn",
            tag: :worker,
            status: :running
          }
        }
      }

      directives = Checkpoint.replay_directives(strategy_state)
      assert length(directives) == 1
      [spawn] = directives
      assert spawn.__struct__ == Jido.Agent.Directive.SpawnAgent
      assert spawn.agent == SomeModule
      assert spawn.tag == :worker
    end

    test "no replay for child in :awaiting_result phase" do
      strategy_state = %{
        child_phases: %{worker: :awaiting_result},
        children: %{
          worker: %ChildRef{
            agent_module: SomeModule,
            agent_id: "child-wait",
            tag: :worker,
            status: :running
          }
        }
      }

      directives = Checkpoint.replay_directives(strategy_state)
      assert directives == []
    end

    test "returns empty when no phases tracked" do
      assert Checkpoint.replay_directives(%{child_phases: %{}, children: %{}}) == []
    end

    test "returns empty when child_phases key is missing" do
      assert Checkpoint.replay_directives(%{}) == []
    end
  end
end
