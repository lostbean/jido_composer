defmodule Jido.Composer.Checkpoint do
  @moduledoc """
  Checkpoint preparation and restore for Composer strategy state.

  Before persisting strategy state, closures must be stripped since they
  cannot be serialized. On restore, they are reattached from the agent
  module's DSL configuration (`strategy_opts`).

  ## Schema Version

  Current checkpoint schema is `:composer_v4`. Migrations:
  - v1 → v2: adds `children` field (empty map default)
  - v2 → v3: adds `checkpoint_status` and `child_phases` fields
  - v3 → v4: replaces `generation_mode` with `stream` boolean
  """

  alias Jido.Agent.Directive

  @schema_version :composer_v4

  @valid_transitions %{
    hibernated: [:resuming],
    resuming: [:resumed],
    resumed: []
  }

  @doc """
  Returns the current checkpoint schema version.
  """
  @spec schema_version() :: atom()
  def schema_version, do: @schema_version

  @doc """
  Validates a checkpoint status transition.
  """
  @spec transition_status(atom(), atom()) :: :ok | {:error, {:invalid_transition, atom(), atom()}}
  def transition_status(current, target) do
    if target in Map.get(@valid_transitions, current, []) do
      :ok
    else
      {:error, {:invalid_transition, current, target}}
    end
  end

  @doc """
  Prepares strategy state for checkpoint by stripping non-serializable
  values (closures/functions) from top-level fields and setting checkpoint status.
  """
  @spec prepare_for_checkpoint(map()) :: map()
  def prepare_for_checkpoint(strategy_state) when is_map(strategy_state) do
    strategy_state
    |> Map.new(fn {key, value} ->
      if is_function(value) do
        {key, nil}
      else
        {key, value}
      end
    end)
    |> Map.put_new(:checkpoint_status, :hibernated)
  end

  @doc """
  Reattaches runtime configuration (closures) from strategy_opts.

  Only restores values that are currently nil in the checkpoint state.
  """
  @spec reattach_runtime_config(map(), keyword()) :: map()
  def reattach_runtime_config(checkpoint_state, strategy_opts) when is_map(checkpoint_state) do
    Enum.reduce(strategy_opts, checkpoint_state, fn {key, value}, acc ->
      if is_function(value) and Map.get(acc, key) == nil do
        Map.put(acc, key, value)
      else
        acc
      end
    end)
  end

  @doc """
  Returns SpawnAgent directives for paused children that need re-spawning.
  """
  @spec pending_child_respawns(map()) :: [Directive.SpawnAgent.t()]
  def pending_child_respawns(strategy_state) do
    strategy_state
    |> Map.get(:children, %{})
    |> Enum.filter(fn {_tag, ref} -> ref.status == :paused end)
    |> Enum.map(fn {_tag, ref} ->
      %Directive.SpawnAgent{
        agent: ref.agent_module,
        tag: ref.tag,
        opts: %{
          id: ref.agent_id,
          checkpoint_key: ref.checkpoint_key
        }
      }
    end)
  end

  @doc """
  Returns directives needed to replay in-flight operations after checkpoint restore.

  Handles both workflow child spawning phases and orchestrator in-flight operations:
  - For workflow states with `child_phases` in `:spawning`, emits `SpawnAgent` directives
  - For orchestrator states with `status: :awaiting_tool` and pending tool calls,
    emits `RunInstruction` directives to re-dispatch those tool calls
  - For orchestrator states with `status: :awaiting_llm`, emits an LLM call directive
  """
  @spec replay_directives(map()) :: [struct()]
  def replay_directives(strategy_state) do
    child_replays = replay_child_phases(strategy_state)
    orchestrator_replays = replay_orchestrator_ops(strategy_state)
    child_replays ++ orchestrator_replays
  end

  defp replay_child_phases(state) do
    # Primary source: child_phases map
    phases = Map.get(state, :child_phases, %{})

    # Backward compat with v3 checkpoints: if child_phases is empty,
    # derive phases from ChildRef.phase fields
    phases =
      if phases == %{} do
        state
        |> Map.get(:children, %{})
        |> Enum.reduce(%{}, fn {tag, ref}, acc ->
          case Map.get(ref, :phase) do
            nil -> acc
            phase -> Map.put(acc, tag, phase)
          end
        end)
      else
        phases
      end

    Enum.flat_map(phases, fn
      {tag, :spawning} ->
        case get_in(state, [:children, tag]) do
          %{agent_module: mod} ->
            [%Directive.SpawnAgent{agent: mod, tag: tag, opts: %{}}]

          _ ->
            []
        end

      {_tag, :awaiting_result} ->
        []

      _ ->
        []
    end)
  end

  defp replay_orchestrator_ops(state) do
    module = Map.get(state, :module)
    status = Map.get(state, :status)

    if module == Jido.Composer.Orchestrator.Strategy do
      replay_orchestrator_status(state, status)
    else
      []
    end
  end

  defp replay_orchestrator_status(state, :awaiting_llm) do
    # Re-emit the LLM call from the current conversation state
    [
      %Directive.RunInstruction{
        instruction: %Jido.Instruction{
          action: Jido.Composer.Orchestrator.LLMAction,
          params: %{
            conversation: Map.get(state, :conversation),
            tool_results: Map.get(state, :completed_tool_results, []),
            tools: Map.get(state, :tools, []),
            model: Map.get(state, :model),
            query: Map.get(state, :query),
            system_prompt: Map.get(state, :system_prompt),
            temperature: Map.get(state, :temperature),
            max_tokens: Map.get(state, :max_tokens),
            stream: Map.get(state, :stream, false),
            output_schema: Map.get(state, :output_schema),
            llm_opts: Map.get(state, :llm_opts, []),
            req_options: Map.get(state, :req_options, [])
          }
        },
        result_action: :orchestrator_llm_result
      }
    ]
  end

  defp replay_orchestrator_status(state, status)
       when status in [:awaiting_tool, :awaiting_tools, :awaiting_tools_and_approval] do
    # Re-dispatch RunInstruction directives for pending tool calls
    pending = Map.get(state, :pending_tool_calls, [])
    nodes = Map.get(state, :nodes, %{})
    context = Map.get(state, :context)
    conversation = Map.get(state, :conversation, [])

    # Extract tool calls from the last assistant message in conversation
    tool_calls_from_conversation =
      conversation
      |> Enum.reverse()
      |> Enum.find_value([], fn
        %{role: "assistant", tool_calls: calls} when is_list(calls) -> calls
        _ -> false
      end)

    # Only re-dispatch calls that are still pending
    pending_set = MapSet.new(pending)

    tool_calls_from_conversation
    |> Enum.filter(fn call -> MapSet.member?(pending_set, call[:id] || call.id) end)
    |> Enum.map(fn call ->
      call = to_tool_call_map(call)
      build_tool_replay_directive(call, nodes, context)
    end)
  end

  defp replay_orchestrator_status(_state, _status), do: []

  defp to_tool_call_map(call) when is_map(call) do
    %{
      id: call[:id] || Map.get(call, "id"),
      name: call[:name] || Map.get(call, "name"),
      arguments: call[:arguments] || Map.get(call, "arguments", %{})
    }
  end

  defp build_tool_replay_directive(call, nodes, %Jido.Composer.Context{} = ctx) do
    alias Jido.Composer.Node.ActionNode
    alias Jido.Composer.Node.AgentNode
    alias Jido.Composer.Orchestrator.AgentTool

    tool_args = AgentTool.to_context(call)

    case nodes[call.name] do
      %ActionNode{action_module: action_module} ->
        merged_ctx = %{ctx | working: Map.merge(ctx.working, tool_args)}
        flat = Jido.Composer.Context.to_flat_map(merged_ctx)

        %Directive.RunInstruction{
          instruction: %Jido.Instruction{action: action_module, params: flat},
          result_action: :orchestrator_tool_result,
          meta: %{call_id: call.id, tool_name: call.name}
        }

      %AgentNode{agent_module: agent_module, opts: opts} ->
        child_ctx = Jido.Composer.Context.fork_for_child(ctx)
        child_flat = Jido.Composer.Context.to_flat_map(child_ctx)
        merged = Map.merge(child_flat, tool_args)

        %Directive.SpawnAgent{
          tag: {:tool_call, call.id, call.name},
          agent: agent_module,
          opts: Map.new(opts) |> Map.put(:context, merged)
        }

      _ ->
        # Unknown node — skip
        nil
    end
  end

  defp build_tool_replay_directive(call, _nodes, _ctx) do
    # Context is not a Context struct (e.g., nil or bare map) — emit a basic directive
    %Directive.RunInstruction{
      instruction: %Jido.Instruction{
        action: :unknown,
        params: %{call_id: call.id, tool_name: call.name}
      },
      result_action: :orchestrator_tool_result,
      meta: %{call_id: call.id, tool_name: call.name}
    }
  end

  @doc """
  Wraps suspend directives with a CheckpointAndStop directive when the suspension
  timeout exceeds the configured `hibernate_after` threshold.

  Returns the original directives list, potentially with CheckpointAndStop appended.
  """
  @spec maybe_add_checkpoint_and_stop([struct()], map()) :: [struct()]
  def maybe_add_checkpoint_and_stop(directives, strategy_state) do
    hibernate_after = Map.get(strategy_state, :hibernate_after)

    if is_integer(hibernate_after) do
      Enum.reduce(directives, directives, fn
        %Jido.Composer.Directive.Suspend{suspension: suspension}, acc ->
          timeout = Map.get(suspension, :timeout, :infinity)

          if is_integer(timeout) and timeout >= hibernate_after do
            checkpoint_directive = %Jido.Composer.Directive.CheckpointAndStop{
              suspension: suspension
            }

            acc ++ [checkpoint_directive]
          else
            acc
          end

        _, acc ->
          acc
      end)
    else
      directives
    end
  end

  @doc """
  Migrates checkpoint state from an older schema version to the current one.
  """
  @spec migrate(map(), non_neg_integer()) :: map()
  def migrate(state, version)

  def migrate(state, v) when v < 1 do
    migrate(state, 1)
  end

  def migrate(state, 1) do
    state
    |> Map.put_new(:children, %{})
    |> migrate(2)
  end

  def migrate(state, 2) do
    state
    |> Map.put_new(:checkpoint_status, :hibernated)
    |> Map.put_new(:child_phases, %{})
    |> migrate(3)
  end

  def migrate(state, 3) do
    stream =
      case Map.get(state, :generation_mode) do
        mode when mode in [:stream_text, :stream_object] -> true
        _ -> false
      end

    state
    |> Map.put_new(:stream, stream)
    |> Map.delete(:generation_mode)
    |> migrate(4)
  end

  def migrate(state, 4), do: state

  def migrate(state, _version), do: state
end
