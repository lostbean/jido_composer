defmodule Jido.Composer.Orchestrator.Strategy do
  @moduledoc """
  Jido.Agent.Strategy implementation for LLM-driven orchestration.

  Implements a ReAct-style (Reason + Act) loop: call LLM, execute tool calls,
  feed results back, repeat until final answer or iteration limit.

  All side effects are dispatched via directives — the strategy itself is pure.
  """

  use Jido.Agent.Strategy

  alias Jido.Agent.Directive
  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.Composer.Checkpoint
  alias Jido.Composer.ChildRef
  alias Jido.Composer.Context
  alias Jido.Composer.Directive.Suspend, as: SuspendDirective
  alias Jido.Composer.Directive.SuspendForHuman
  alias Jido.Composer.HITL.{ApprovalRequest, ApprovalResponse}
  alias Jido.Composer.Node.ActionNode
  alias Jido.Composer.Node.AgentNode
  alias Jido.Composer.NodeIO
  alias Jido.Composer.Orchestrator.AgentTool
  alias Jido.Composer.Suspension

  # -- init/2 --

  @impl true
  def init(agent, ctx) do
    opts = ctx.strategy_opts

    node_modules = opts[:nodes] || []
    nodes = build_nodes(node_modules)
    tools = Enum.map(nodes, fn {_name, node} -> AgentTool.to_tool(node) end)
    # Pre-create atoms for tool name scoping. This is safe because the set of
    # node names is bounded and determined at compile time by the DSL.
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    name_atoms = Map.new(nodes, fn {name, _node} -> {name, String.to_atom(name)} end)

    gated_node_names = MapSet.new(opts[:gated_nodes] || [])
    approval_policy = opts[:approval_policy]
    ambient_keys = opts[:ambient] || []
    fork_fns = opts[:fork_fns] || %{}

    agent =
      StratState.put(agent, %{
        module: __MODULE__,
        status: :idle,
        nodes: nodes,
        model: opts[:model],
        system_prompt: opts[:system_prompt],
        temperature: opts[:temperature],
        max_tokens: opts[:max_tokens],
        generation_mode: opts[:generation_mode] || :generate_text,
        output_schema: opts[:output_schema],
        llm_opts: opts[:llm_opts] || [],
        conversation: nil,
        tools: tools,
        pending_tool_calls: [],
        completed_tool_results: [],
        context: Context.new(fork_fns: fork_fns),
        ambient_keys: ambient_keys,
        iteration: 0,
        max_iterations: opts[:max_iterations] || 10,
        req_options: opts[:req_options] || [],
        name_atoms: name_atoms,
        result: nil,
        query: nil,
        gated_node_names: gated_node_names,
        approval_policy: approval_policy,
        rejection_policy: opts[:rejection_policy] || :continue_siblings,
        gated_calls: %{},
        suspended_calls: %{},
        children: %{}
      })

    {agent, []}
  end

  # -- cmd/3 --

  @impl true
  def cmd(agent, [%Jido.Instruction{action: :orchestrator_start} = instr | _], _ctx) do
    query = instr.params[:query] || instr.params["query"]
    params = Map.drop(instr.params, [:query, "query"])

    agent =
      StratState.update(agent, fn s ->
        new_context = build_start_context(s.context, params, s)
        %{s | status: :awaiting_llm, query: query, iteration: 0, context: new_context}
      end)

    emit_llm_call(agent)
  end

  def cmd(agent, [%Jido.Instruction{action: :orchestrator_llm_result} = instr | _], _ctx) do
    params = instr.params

    case params do
      %{status: :ok, result: %{response: response, conversation: conversation}} ->
        handle_llm_response(agent, response, conversation)

      %{status: :error, result: %{error: reason}} ->
        agent =
          StratState.update(agent, fn s ->
            %{s | status: :error, result: inspect(reason)}
          end)

        {agent, []}

      _ ->
        agent =
          StratState.update(agent, fn s ->
            %{s | status: :error, result: "unexpected LLM result format"}
          end)

        {agent, []}
    end
  end

  def cmd(agent, [%Jido.Instruction{action: :orchestrator_tool_result} = instr | _], _ctx) do
    params = instr.params
    meta = params[:meta] || params["meta"] || %{}
    call_id = meta[:call_id] || meta["call_id"]
    tool_name = meta[:tool_name] || meta["tool_name"]

    case params[:status] do
      :suspend ->
        handle_tool_suspension(agent, call_id, tool_name, params)

      status when status in [:ok, :error] ->
        tool_result =
          case status do
            :ok ->
              AgentTool.to_tool_result(call_id, tool_name, {:ok, params[:result]})

            :error ->
              AgentTool.to_tool_result(call_id, tool_name, {:error, params[:result]})
          end

        # Scope result under tool name in context (only on success)
        scope_key = scope_atom(agent, tool_name)

        scoped_result =
          case status do
            :ok -> params[:result] || %{}
            :error -> %{error: inspect(params[:result])}
          end

        agent =
          StratState.update(agent, fn s ->
            new_pending = List.delete(s.pending_tool_calls, call_id)
            new_completed = s.completed_tool_results ++ [tool_result]
            new_context = Context.apply_result(s.context, scope_key, scoped_result)

            %{
              s
              | pending_tool_calls: new_pending,
                completed_tool_results: new_completed,
                context: new_context
            }
          end)

        check_all_tools_done(agent)

      other ->
        {agent,
         [
           %Directive.Error{
             error: %RuntimeError{
               message: "Unexpected tool result status: #{inspect(other)}"
             }
           }
         ]}
    end
  end

  def cmd(agent, [%Jido.Instruction{action: :orchestrator_child_started} = instr | _], _ctx) do
    params = instr.params
    tag = params[:tag]

    child_ref =
      ChildRef.new(
        agent_module: params[:agent_module],
        agent_id: params[:agent_id],
        tag: tag,
        status: :running
      )

    agent =
      StratState.update(agent, fn s ->
        %{s | children: Map.put(s.children, tag, child_ref)}
      end)

    {agent, []}
  end

  def cmd(agent, [%Jido.Instruction{action: :orchestrator_child_result} = instr | _], _ctx) do
    params = instr.params
    tag = params[:tag]

    {call_id, tool_name} =
      case tag do
        {:tool_call, id, name} -> {id, name}
        _ -> {nil, nil}
      end

    {status, result} =
      case params[:result] do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
        other -> {:ok, other}
      end

    tool_result = AgentTool.to_tool_result(call_id, tool_name, {status, result})

    scope_key = scope_atom(agent, tool_name)

    scoped_result =
      case status do
        :ok -> result || %{}
        :error -> %{error: inspect(result)}
      end

    agent =
      StratState.update(agent, fn s ->
        new_pending = List.delete(s.pending_tool_calls, call_id)
        new_completed = s.completed_tool_results ++ [tool_result]
        new_context = Context.apply_result(s.context, scope_key, scoped_result)

        %{
          s
          | pending_tool_calls: new_pending,
            completed_tool_results: new_completed,
            context: new_context
        }
      end)

    check_all_tools_done(agent)
  end

  def cmd(agent, [%Jido.Instruction{action: :orchestrator_child_exit} = instr | _], _ctx) do
    params = instr.params
    tag = params[:tag]
    exit_status = if params[:reason] == :normal, do: :completed, else: :failed

    agent =
      StratState.update(agent, fn s ->
        children =
          Map.update(s.children, tag, nil, fn ref ->
            %{ref | status: exit_status}
          end)

        %{s | children: children}
      end)

    {agent, []}
  end

  def cmd(agent, [%Jido.Instruction{action: :hitl_response} = instr | _], _ctx) do
    strat = StratState.get(agent)
    response_data = instr.params
    request_id = response_data.request_id

    case Map.get(strat.gated_calls, request_id) do
      nil ->
        {agent,
         [
           %Directive.Error{
             error: %RuntimeError{message: "No pending approval for #{request_id}"}
           }
         ]}

      %{request: request, call: call} ->
        case ApprovalResponse.new(
               request_id: response_data.request_id,
               decision: response_data.decision,
               data: Map.get(response_data, :data),
               respondent: Map.get(response_data, :respondent),
               comment: Map.get(response_data, :comment),
               responded_at: Map.get(response_data, :responded_at, DateTime.utc_now())
             ) do
          {:ok, response} ->
            case ApprovalResponse.validate(response, request) do
              :ok ->
                handle_approval_decision(agent, request_id, response, call)

              {:error, reason} ->
                {agent,
                 [
                   %Directive.Error{
                     error: %RuntimeError{message: "HITL validation failed: #{reason}"}
                   }
                 ]}
            end

          {:error, reason} ->
            {agent,
             [
               %Directive.Error{
                 error: %RuntimeError{message: "HITL response invalid: #{reason}"}
               }
             ]}
        end
    end
  end

  def cmd(agent, [%Jido.Instruction{action: :hitl_timeout} = instr | _], _ctx) do
    strat = StratState.get(agent)
    request_id = instr.params[:request_id]

    case Map.get(strat.gated_calls, request_id) do
      %{call: call} ->
        # Treat timeout as rejection
        handle_approval_rejection(agent, request_id, call, "Approval timed out")

      nil ->
        {agent, []}
    end
  end

  # Generalized suspend resume for orchestrator tool calls
  def cmd(agent, [%Jido.Instruction{action: :suspend_resume} = instr | _], _ctx) do
    strat = StratState.get(agent)
    params = instr.params
    suspension_id = params[:suspension_id]

    case Map.get(strat.suspended_calls, suspension_id) do
      nil ->
        {agent,
         [
           %Directive.Error{
             error: %RuntimeError{message: "No suspended call for #{inspect(suspension_id)}"}
           }
         ]}

      %{suspension: _suspension, call: call} ->
        # Resume the suspended tool call — build and dispatch the directive
        outcome = params[:outcome] || :ok
        data = params[:data]

        if outcome == :ok and data != nil do
          # Provide data directly as tool result
          tool_result = AgentTool.to_tool_result(call.id, call.name, {:ok, data})
          scope_key = scope_atom(agent, call.name)

          agent =
            StratState.update(agent, fn s ->
              new_suspended = Map.delete(s.suspended_calls, suspension_id)
              new_completed = s.completed_tool_results ++ [tool_result]
              new_context = Context.apply_result(s.context, scope_key, data)

              %{
                s
                | suspended_calls: new_suspended,
                  completed_tool_results: new_completed,
                  context: new_context
              }
            end)

          check_all_tools_done(agent)
        else
          # Re-dispatch the tool call
          agent =
            StratState.update(agent, fn s ->
              new_suspended = Map.delete(s.suspended_calls, suspension_id)
              new_pending = s.pending_tool_calls ++ [call.id]
              %{s | suspended_calls: new_suspended, pending_tool_calls: new_pending}
            end)

          state = StratState.get(agent)
          directive = build_tool_directive(call, state.nodes, state.context)
          {agent, [directive]}
        end
    end
  end

  # Generalized suspend timeout for orchestrator
  def cmd(agent, [%Jido.Instruction{action: :suspend_timeout} = instr | _], _ctx) do
    strat = StratState.get(agent)
    suspension_id = instr.params[:suspension_id]

    case Map.get(strat.suspended_calls, suspension_id) do
      %{call: call} ->
        # Treat as error result for the tool call
        tool_result =
          AgentTool.to_tool_result(
            call.id,
            call.name,
            {:error, "Suspension timed out"}
          )

        scope_key = scope_atom(agent, call.name)

        agent =
          StratState.update(agent, fn s ->
            new_suspended = Map.delete(s.suspended_calls, suspension_id)
            new_completed = s.completed_tool_results ++ [tool_result]

            new_context =
              Context.apply_result(s.context, scope_key, %{error: "suspension_timeout"})

            %{
              s
              | suspended_calls: new_suspended,
                completed_tool_results: new_completed,
                context: new_context
            }
          end)

        check_all_tools_done(agent)

      nil ->
        {agent, []}
    end
  end

  def cmd(agent, [%Jido.Instruction{action: :fan_out_branch_result} | _], _ctx) do
    {agent,
     [
       %Directive.Error{
         error: %RuntimeError{message: "Orchestrator does not support FanOut branches"}
       }
     ]}
  end

  def cmd(agent, [%Jido.Instruction{action: :child_hibernated} = instr | _], _ctx) do
    params = instr.params
    tag = params[:tag]

    agent =
      StratState.update(agent, fn s ->
        children =
          Map.update(s.children, tag, nil, fn ref ->
            %{
              ref
              | status: :paused,
                checkpoint_key: params[:checkpoint_key],
                suspension_id: params[:suspension_id]
            }
          end)

        %{s | children: children}
      end)

    {agent, []}
  end

  def cmd(agent, _instructions, _ctx) do
    {agent, []}
  end

  # -- signal_routes/1 --

  @impl true
  def signal_routes(_ctx) do
    [
      {"composer.orchestrator.query", {:strategy_cmd, :orchestrator_start}},
      {"composer.orchestrator.child.result", {:strategy_cmd, :orchestrator_child_result}},
      {"jido.agent.child.started", {:strategy_cmd, :orchestrator_child_started}},
      {"jido.agent.child.exit", {:strategy_cmd, :orchestrator_child_exit}},
      {"composer.suspend.resume", {:strategy_cmd, :suspend_resume}},
      {"composer.suspend.timeout", {:strategy_cmd, :suspend_timeout}},
      {"composer.hitl.response", {:strategy_cmd, :hitl_response}},
      {"composer.hitl.timeout", {:strategy_cmd, :hitl_timeout}},
      {"composer.child.hibernated", {:strategy_cmd, :child_hibernated}}
    ]
  end

  # -- snapshot/2 --

  @impl true
  def snapshot(agent, _ctx) do
    strat = StratState.get(agent, %{})
    status = Map.get(strat, :status, :idle)

    details = %{
      iteration: Map.get(strat, :iteration, 0),
      context:
        case Map.get(strat, :context) do
          %Context{} = ctx -> Context.to_flat_map(ctx)
          other -> other || %{}
        end
    }

    details =
      case {status, Map.get(strat, :gated_calls, %{})} do
        {s, gated}
        when s in [:awaiting_approval, :awaiting_tools_and_approval] and gated != %{} ->
          [{request_id, %{request: request}} | _] = Map.to_list(gated)

          Map.merge(details, %{
            reason: :awaiting_approval,
            request_id: request_id,
            node_name: Map.get(request.metadata, :tool_name)
          })

        _ ->
          details
      end

    raw_result = Map.get(strat, :result)

    snapshot_result =
      case raw_result do
        %NodeIO{} -> NodeIO.unwrap(raw_result)
        other -> other
      end

    %Jido.Agent.Strategy.Snapshot{
      status: status,
      done?: status in [:completed, :error],
      result: snapshot_result,
      details: details
    }
  end

  # -- Private --

  defp handle_llm_response(agent, response, conversation) do
    agent =
      StratState.update(agent, fn s ->
        %{s | conversation: conversation, iteration: s.iteration + 1}
      end)

    state = StratState.get(agent)

    case response do
      {:final_answer, text} ->
        agent =
          StratState.update(agent, fn s ->
            %{s | status: :completed, result: NodeIO.text(text)}
          end)

        {agent, []}

      {:tool_calls, calls} ->
        dispatch_tool_calls(agent, calls, state)

      {:tool_calls, calls, _reasoning} ->
        dispatch_tool_calls(agent, calls, state)

      {:error, reason} ->
        agent =
          StratState.update(agent, fn s ->
            %{s | status: :error, result: inspect(reason)}
          end)

        {agent, []}
    end
  end

  defp dispatch_tool_calls(agent, calls, state) do
    if state.iteration >= state.max_iterations do
      agent =
        StratState.update(agent, fn s ->
          %{s | status: :error, result: "max iteration limit reached (#{s.max_iterations})"}
        end)

      {agent, []}
    else
      {ungated, gated} =
        Enum.split_with(calls, fn call ->
          not requires_approval?(call, state)
        end)

      ungated_ids = Enum.map(ungated, & &1.id)

      # Build gated_calls map: request_id -> %{request, call}
      gated_results =
        Enum.reduce_while(gated, {:ok, %{}}, fn call, {:ok, acc} ->
          case ApprovalRequest.new(
                 prompt: "Approve tool call: #{call.name}(#{inspect(call.arguments)})",
                 allowed_responses: [:approved, :rejected],
                 visible_context: call.arguments,
                 metadata: %{tool_call_id: call.id, tool_name: call.name}
               ) do
            {:ok, request} ->
              {:cont, {:ok, Map.put(acc, request.id, %{request: request, call: call})}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end)

      case gated_results do
        {:error, reason} ->
          agent =
            StratState.update(agent, fn s ->
              %{s | status: :error, result: "Failed to create approval request: #{reason}"}
            end)

          {agent, []}

        {:ok, gated_entries} ->
          agent =
            StratState.update(agent, fn s ->
              new_status =
                cond do
                  gated == [] -> :awaiting_tools
                  ungated == [] -> :awaiting_approval
                  true -> :awaiting_tools_and_approval
                end

              %{
                s
                | status: new_status,
                  pending_tool_calls: ungated_ids,
                  completed_tool_results: [],
                  gated_calls: gated_entries
              }
            end)

          # Build directives for ungated calls
          ungated_directives =
            Enum.map(ungated, fn call ->
              build_tool_directive(call, state.nodes, state.context)
            end)

          # Build SuspendForHuman directives for gated calls
          gated_directives =
            Enum.reduce(gated_entries, [], fn {_req_id, %{request: request}}, acc ->
              case SuspendForHuman.new(approval_request: request) do
                {:ok, directive} -> acc ++ [directive]
                {:error, _reason} -> acc
              end
            end)

          {agent, ungated_directives ++ gated_directives}
      end
    end
  end

  defp build_tool_directive(call, nodes, %Context{} = ctx) do
    tool_args = AgentTool.to_context(call)

    case nodes[call.name] do
      %ActionNode{action_module: action_module} ->
        merged_ctx = %{ctx | working: Map.merge(ctx.working, tool_args)}
        flat = Context.to_flat_map(merged_ctx)

        instruction = %Jido.Instruction{
          action: action_module,
          params: flat
        }

        %Directive.RunInstruction{
          instruction: instruction,
          result_action: :orchestrator_tool_result,
          meta: %{call_id: call.id, tool_name: call.name}
        }

      %AgentNode{agent_module: agent_module, opts: opts} ->
        child_ctx = Context.fork_for_child(ctx)
        child_flat = Context.to_flat_map(child_ctx)
        merged = Map.merge(child_flat, tool_args)

        %Directive.SpawnAgent{
          tag: {:tool_call, call.id, call.name},
          agent: agent_module,
          opts: Map.new(opts) |> Map.put(:context, merged)
        }
    end
  end

  defp emit_llm_call(agent) do
    state = StratState.get(agent)

    # Build an internal instruction for the LLM call
    instruction = %Jido.Instruction{
      action: Jido.Composer.Orchestrator.LLMAction,
      params: %{
        conversation: state.conversation,
        tool_results: state.completed_tool_results,
        tools: state.tools,
        model: state.model,
        query: state.query,
        system_prompt: state.system_prompt,
        temperature: state.temperature,
        max_tokens: state.max_tokens,
        generation_mode: state.generation_mode,
        output_schema: state.output_schema,
        llm_opts: state.llm_opts,
        req_options: state.req_options
      }
    }

    directive = %Directive.RunInstruction{
      instruction: instruction,
      result_action: :orchestrator_llm_result
    }

    {agent, [directive]}
  end

  defp handle_approval_decision(agent, request_id, response, call) do
    case response.decision do
      :approved ->
        # Remove from gated_calls, dispatch the tool
        state = StratState.get(agent)

        agent =
          StratState.update(agent, fn s ->
            new_gated = Map.delete(s.gated_calls, request_id)
            new_pending = s.pending_tool_calls ++ [call.id]

            new_status =
              cond do
                new_gated == %{} and new_pending != [] -> :awaiting_tools
                new_gated == %{} -> :awaiting_tools
                new_pending != [] -> :awaiting_tools_and_approval
                true -> :awaiting_approval
              end

            %{s | gated_calls: new_gated, pending_tool_calls: new_pending, status: new_status}
          end)

        directive = build_tool_directive(call, state.nodes, state.context)
        {agent, [directive]}

      :rejected ->
        comment = response.comment || "No reason provided"
        handle_approval_rejection(agent, request_id, call, comment)
    end
  end

  defp handle_approval_rejection(agent, request_id, call, reason) do
    state = StratState.get(agent)

    case state.rejection_policy do
      :abort_iteration ->
        agent =
          StratState.update(agent, fn s ->
            %{
              s
              | status: :error,
                result: "Iteration aborted: tool #{call.name} rejected. Reason: #{reason}",
                gated_calls: %{},
                pending_tool_calls: []
            }
          end)

        {agent, []}

      :cancel_siblings ->
        # Cancel all pending tool calls with synthetic results
        cancel_results =
          Enum.map(state.pending_tool_calls, fn pending_id ->
            AgentTool.to_tool_result(
              pending_id,
              "cancelled",
              {:error, "Cancelled due to sibling rejection"}
            )
          end)

        rejection_result =
          AgentTool.to_tool_result(
            call.id,
            call.name,
            {:error,
             "REJECTED by human reviewer. Reason: #{reason}. Choose a different approach."}
          )

        scope_key = scope_atom(agent, call.name)
        rejection_data = %{error: "REJECTED: #{reason}"}

        agent =
          StratState.update(agent, fn s ->
            new_gated = Map.delete(s.gated_calls, request_id)
            new_completed = s.completed_tool_results ++ cancel_results ++ [rejection_result]
            new_context = Context.apply_result(s.context, scope_key, rejection_data)

            %{
              s
              | gated_calls: new_gated,
                completed_tool_results: new_completed,
                context: new_context,
                pending_tool_calls: []
            }
          end)

        check_all_tools_done(agent)

      _continue_siblings ->
        # Default: inject synthetic rejection result, let siblings finish
        tool_result =
          AgentTool.to_tool_result(
            call.id,
            call.name,
            {:error,
             "REJECTED by human reviewer. Reason: #{reason}. Choose a different approach."}
          )

        scope_key = scope_atom(agent, call.name)
        rejection_data = %{error: "REJECTED: #{reason}"}

        agent =
          StratState.update(agent, fn s ->
            new_gated = Map.delete(s.gated_calls, request_id)
            new_completed = s.completed_tool_results ++ [tool_result]
            new_context = Context.apply_result(s.context, scope_key, rejection_data)

            %{
              s
              | gated_calls: new_gated,
                completed_tool_results: new_completed,
                context: new_context
            }
          end)

        check_all_tools_done(agent)
    end
  end

  defp handle_tool_suspension(agent, call_id, tool_name, params) do
    reason = params[:reason] || :custom
    suspension_meta = params[:suspension_metadata] || %{}

    case Suspension.new(
           reason: reason,
           timeout: Map.get(suspension_meta, :timeout, :infinity),
           resume_signal: "composer.suspend.resume",
           metadata: Map.merge(suspension_meta, %{tool_call_id: call_id, tool_name: tool_name})
         ) do
      {:ok, suspension} ->
        call = %{id: call_id, name: tool_name, arguments: params[:arguments] || %{}}

        agent =
          StratState.update(agent, fn s ->
            new_pending = List.delete(s.pending_tool_calls, call_id)

            new_suspended =
              Map.put(s.suspended_calls, suspension.id, %{suspension: suspension, call: call})

            %{s | pending_tool_calls: new_pending, suspended_calls: new_suspended}
          end)

        directive = %SuspendDirective{suspension: suspension}

        # Check if other tools are still pending
        state = StratState.get(agent)

        if state.pending_tool_calls == [] and state.gated_calls == %{} do
          agent = StratState.update(agent, fn s -> %{s | status: :awaiting_suspension} end)
          {agent, [directive]}
        else
          {agent, [directive]}
        end

      {:error, reason} ->
        # Treat as error result for the tool call
        tool_result = AgentTool.to_tool_result(call_id, tool_name, {:error, reason})
        scope_key = scope_atom(agent, tool_name)

        agent =
          StratState.update(agent, fn s ->
            new_pending = List.delete(s.pending_tool_calls, call_id)
            new_completed = s.completed_tool_results ++ [tool_result]
            new_context = Context.apply_result(s.context, scope_key, %{error: reason})

            %{
              s
              | pending_tool_calls: new_pending,
                completed_tool_results: new_completed,
                context: new_context
            }
          end)

        check_all_tools_done(agent)
    end
  end

  defp check_all_tools_done(agent) do
    state = StratState.get(agent)

    all_clear =
      state.pending_tool_calls == [] and
        state.gated_calls == %{} and
        state.suspended_calls == %{}

    if all_clear do
      agent = StratState.update(agent, fn s -> %{s | status: :awaiting_llm} end)
      emit_llm_call(agent)
    else
      new_status =
        cond do
          state.suspended_calls != %{} and state.pending_tool_calls == [] and
              state.gated_calls == %{} ->
            :awaiting_suspension

          state.gated_calls == %{} and state.suspended_calls == %{} ->
            :awaiting_tools

          state.pending_tool_calls == [] and state.suspended_calls == %{} ->
            :awaiting_approval

          state.suspended_calls != %{} and state.pending_tool_calls != [] ->
            :awaiting_tools_and_suspension

          true ->
            :awaiting_tools_and_approval
        end

      agent = StratState.update(agent, fn s -> %{s | status: new_status} end)
      {agent, []}
    end
  end

  defp requires_approval?(call, state) do
    # Static gating by name
    if MapSet.member?(state.gated_node_names, call.name) do
      true
    else
      # Dynamic policy function
      case state.approval_policy do
        nil ->
          false

        policy when is_function(policy, 2) ->
          policy.(call, Context.to_flat_map(state.context)) == :require_approval
      end
    end
  end

  defp scope_atom(agent, tool_name) do
    strat = StratState.get(agent)

    case Map.fetch(strat.name_atoms, tool_name) do
      {:ok, atom} ->
        atom

      :error ->
        raise ArgumentError,
              "unknown tool name #{inspect(tool_name)}, " <>
                "expected one of: #{inspect(Map.keys(strat.name_atoms))}"
    end
  end

  # -- Checkpoint hooks --

  @doc false
  def prepare_for_checkpoint(agent) do
    strat = StratState.get(agent)
    cleaned = Checkpoint.prepare_for_checkpoint(strat)
    StratState.put(agent, cleaned)
  end

  @doc false
  def reattach_runtime_config(agent, strategy_opts) do
    strat = StratState.get(agent)
    restored = Checkpoint.reattach_runtime_config(strat, strategy_opts)
    StratState.put(agent, restored)
  end

  defp build_nodes(modules) when is_list(modules) do
    Map.new(modules, fn
      {mod, opts} when is_atom(mod) and is_list(opts) ->
        if Jido.Composer.Node.agent_module?(mod) do
          {:ok, node} = AgentNode.new(mod, opts)
          {AgentNode.name(node), node}
        else
          {:ok, node} = ActionNode.new(mod, opts)
          {ActionNode.name(node), node}
        end

      mod when is_atom(mod) ->
        if Jido.Composer.Node.agent_module?(mod) do
          {:ok, node} = AgentNode.new(mod)
          {AgentNode.name(node), node}
        else
          {:ok, node} = ActionNode.new(mod)
          {ActionNode.name(node), node}
        end

      %ActionNode{} = node ->
        {ActionNode.name(node), node}

      %AgentNode{} = node ->
        {AgentNode.name(node), node}
    end)
  end

  defp build_start_context(%Context{} = current_ctx, params, strat) do
    ambient_keys = Map.get(strat, :ambient_keys, [])

    # If parent sent __ambient__ (from Context.to_flat_map), merge it
    {inherited_ambient, params} =
      case Map.pop(params, :__ambient__) do
        {nil, params} -> {%{}, params}
        {ambient_map, params} -> {ambient_map, params}
      end

    if ambient_keys == [] and inherited_ambient == %{} do
      %{current_ctx | working: Map.merge(current_ctx.working, params)}
    else
      {ambient_vals, working_vals} = Map.split(params, ambient_keys)
      ambient = current_ctx.ambient |> Map.merge(inherited_ambient) |> Map.merge(ambient_vals)
      working = Map.merge(current_ctx.working, working_vals)

      %Context{
        ambient: ambient,
        working: working,
        fork_fns: Map.merge(current_ctx.fork_fns, Map.get(strat, :fork_fns, %{}))
      }
    end
  end
end
