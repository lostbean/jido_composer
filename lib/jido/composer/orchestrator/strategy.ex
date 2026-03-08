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
  alias Jido.Composer.ApprovalGate
  alias Jido.Composer.Checkpoint
  alias Jido.Composer.Children
  alias Jido.Composer.Context
  alias Jido.Composer.ToolConcurrency
  alias Jido.Composer.Directive.Suspend, as: SuspendDirective
  alias Jido.Composer.Directive.SuspendForHuman
  alias Jido.Composer.HITL.ApprovalResponse
  alias Jido.Composer.Node.ActionNode
  alias Jido.Composer.Node.AgentNode
  alias Jido.Composer.NodeIO
  alias Jido.Composer.Orchestrator.AgentTool
  alias Jido.Composer.Orchestrator.StatusComputer
  alias Jido.Composer.Suspension

  # -- init/2 --

  @impl true
  def init(agent, ctx) do
    opts = ctx.strategy_opts
    existing = StratState.get(agent, %{})

    if Map.get(existing, :module) == __MODULE__ and Map.get(existing, :status) != :idle do
      restore_runtime_fields(agent, existing, opts)
    else
      fresh_init(agent, opts)
    end
  end

  defp restore_runtime_fields(agent, existing, opts) do
    node_modules = opts[:nodes] || []
    nodes = build_nodes(node_modules)
    tools = Enum.map(nodes, fn {_name, node} -> AgentTool.to_tool(node) end)
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    name_atoms = Map.new(nodes, fn {name, _node} -> {name, String.to_atom(name)} end)

    {tools, name_atoms, term_name, term_mod} =
      build_termination_tool(opts[:termination_tool], tools, name_atoms)

    # Restore max_concurrency into the ToolConcurrency struct
    tc = Map.get(existing, :tool_concurrency, ToolConcurrency.new())
    max_tc = opts[:max_tool_concurrency] || tc.max_concurrency
    tc = %{tc | max_concurrency: max_tc}

    # Restore approval_gate with runtime closures from opts
    ag = Map.get(existing, :approval_gate, ApprovalGate.new())

    ag = %{
      ag
      | gated_node_names: MapSet.new(opts[:gated_nodes] || []),
        approval_policy: opts[:approval_policy]
    }

    restored =
      existing
      |> Map.put(:nodes, nodes)
      |> Map.put(:tools, tools)
      |> Map.put(:name_atoms, name_atoms)
      |> Map.put(:approval_gate, ag)
      |> Map.put(:req_options, opts[:req_options] || existing[:req_options] || [])
      |> Map.put(:tool_concurrency, tc)
      |> Map.put(:termination_tool_name, term_name)
      |> Map.put(:termination_tool_mod, term_mod)

    agent = StratState.put(agent, restored)
    {agent, []}
  end

  defp fresh_init(agent, opts) do
    node_modules = opts[:nodes] || []
    nodes = build_nodes(node_modules)
    tools = Enum.map(nodes, fn {_name, node} -> AgentTool.to_tool(node) end)
    # Pre-create atoms for tool name scoping. This is safe because the set of
    # node names is bounded and determined at compile time by the DSL.
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    name_atoms = Map.new(nodes, fn {name, _node} -> {name, String.to_atom(name)} end)

    ambient_keys = opts[:ambient] || []
    fork_fns = opts[:fork_fns] || %{}

    {tools, name_atoms, term_name, term_mod} =
      build_termination_tool(opts[:termination_tool], tools, name_atoms)

    agent =
      StratState.put(agent, %{
        module: __MODULE__,
        status: :idle,
        nodes: nodes,
        model: opts[:model],
        system_prompt: opts[:system_prompt],
        temperature: opts[:temperature],
        max_tokens: opts[:max_tokens],
        stream: opts[:stream] || false,
        llm_opts: opts[:llm_opts] || [],
        conversation: nil,
        tools: tools,
        tool_concurrency: ToolConcurrency.new(max_concurrency: opts[:max_tool_concurrency]),
        context: Context.new(fork_fns: fork_fns),
        ambient_keys: ambient_keys,
        iteration: 0,
        max_iterations: opts[:max_iterations] || 10,
        req_options: opts[:req_options] || [],
        name_atoms: name_atoms,
        result: nil,
        query: nil,
        approval_gate:
          ApprovalGate.new(
            gated_nodes: opts[:gated_nodes] || [],
            approval_policy: opts[:approval_policy],
            rejection_policy: opts[:rejection_policy] || :continue_siblings
          ),
        suspended_calls: %{},
        children: Children.new(),
        hibernate_after: opts[:hibernate_after],
        termination_tool_name: term_name,
        termination_tool_mod: term_mod
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
        # Check if tool signaled suspension via effects (runtime DirectiveExec path)
        if status == :ok and :suspend in List.wrap(params[:effects]) do
          handle_tool_suspension(agent, call_id, tool_name, params)
        else
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
              new_tc = ToolConcurrency.record_result(s.tool_concurrency, call_id, tool_result)
              new_context = Context.apply_result(s.context, scope_key, scoped_result)

              %{s | tool_concurrency: new_tc, context: new_context}
            end)

          {agent, queue_directives} = dispatch_queued_tool_calls(agent)
          {agent, done_directives} = check_all_tools_done(agent)
          {agent, queue_directives ++ done_directives}
        end

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

    agent =
      StratState.update(agent, fn s ->
        %{
          s
          | children:
              Children.register_started(s.children, tag,
                agent_module: params[:agent_module],
                agent_id: params[:agent_id]
              )
        }
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
        new_tc = ToolConcurrency.record_result(s.tool_concurrency, call_id, tool_result)
        new_context = Context.apply_result(s.context, scope_key, scoped_result)

        %{
          s
          | tool_concurrency: new_tc,
            context: new_context,
            children: Children.record_result(s.children, tag)
        }
      end)

    {agent, queue_directives} = dispatch_queued_tool_calls(agent)
    {agent, done_directives} = check_all_tools_done(agent)
    {agent, queue_directives ++ done_directives}
  end

  def cmd(agent, [%Jido.Instruction{action: :orchestrator_child_exit} = instr | _], _ctx) do
    params = instr.params
    tag = params[:tag]

    agent =
      StratState.update(agent, fn s ->
        %{s | children: Children.record_exit(s.children, tag, params[:reason])}
      end)

    {agent, []}
  end

  def cmd(agent, [%Jido.Instruction{action: :hitl_response} = instr | _], _ctx) do
    strat = StratState.get(agent)
    response_data = instr.params
    request_id = response_data.request_id

    case ApprovalGate.get(strat.approval_gate, request_id) do
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

    case ApprovalGate.get(strat.approval_gate, request_id) do
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

              new_tc = %{
                s.tool_concurrency
                | completed: s.tool_concurrency.completed ++ [tool_result]
              }

              new_context = Context.apply_result(s.context, scope_key, data)

              %{
                s
                | suspended_calls: new_suspended,
                  tool_concurrency: new_tc,
                  context: new_context
              }
            end)

          check_all_tools_done(agent)
        else
          # Re-dispatch the tool call
          agent =
            StratState.update(agent, fn s ->
              new_suspended = Map.delete(s.suspended_calls, suspension_id)
              new_tc = ToolConcurrency.add_pending(s.tool_concurrency, call.id)
              %{s | suspended_calls: new_suspended, tool_concurrency: new_tc}
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

            new_tc = %{
              s.tool_concurrency
              | completed: s.tool_concurrency.completed ++ [tool_result]
            }

            new_context =
              Context.apply_result(s.context, scope_key, %{error: "suspension_timeout"})

            %{s | suspended_calls: new_suspended, tool_concurrency: new_tc, context: new_context}
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
        %{
          s
          | children:
              Children.record_hibernation(
                s.children,
                tag,
                params[:checkpoint_key],
                params[:suspension_id]
              )
        }
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
      case {status, Map.get(strat, :approval_gate)} do
        {s, %ApprovalGate{gated_calls: gated}}
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
      case find_termination_call(calls, state.termination_tool_name) do
        {:terminated, call} ->
          handle_termination(agent, call, state)

        :not_terminated ->
          dispatch_regular_tool_calls(agent, calls, state)
      end
    end
  end

  defp dispatch_regular_tool_calls(agent, calls, state) do
    case ApprovalGate.partition_calls(state.approval_gate, calls, state.context) do
      {:error, reason} ->
        agent =
          StratState.update(agent, fn s ->
            %{s | status: :error, result: "Failed to create approval request: #{reason}"}
          end)

        {agent, []}

      {:ok, ungated, gated_entries} ->
        tc = state.tool_concurrency
        {to_dispatch, to_queue} = ToolConcurrency.split_for_dispatch(tc, ungated)
        dispatched_ids = Enum.map(to_dispatch, & &1.id)

        agent =
          StratState.update(agent, fn s ->
            new_tc = ToolConcurrency.dispatch(s.tool_concurrency, dispatched_ids, to_queue)
            new_ag = ApprovalGate.gate_calls(s.approval_gate, gated_entries)
            new_status = StatusComputer.compute(new_tc, new_ag, s.suspended_calls)

            %{s | status: new_status, tool_concurrency: new_tc, approval_gate: new_ag}
          end)

        # Build directives for dispatched (ungated, within concurrency limit) calls
        ungated_directives =
          Enum.map(to_dispatch, fn call ->
            build_tool_directive(call, state.nodes, state.context)
          end)

        # Track spawning phase for AgentNode tool calls
        spawn_phases =
          ungated_directives
          |> Enum.filter(&match?(%Directive.SpawnAgent{}, &1))
          |> Map.new(fn %Directive.SpawnAgent{tag: tag} -> {tag, :spawning} end)

        agent =
          if spawn_phases != %{} do
            StratState.update(agent, fn s ->
              %{s | children: Children.merge_phases(s.children, spawn_phases)}
            end)
          else
            agent
          end

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

    directive =
      build_llm_instruction(%{
        conversation: state.conversation,
        tool_results: state.tool_concurrency.completed,
        tools: state.tools,
        model: state.model,
        query: state.query,
        system_prompt: state.system_prompt,
        temperature: state.temperature,
        max_tokens: state.max_tokens,
        stream: state.stream,
        llm_opts: state.llm_opts,
        req_options: state.req_options
      })

    {agent, [directive]}
  end

  defp build_llm_instruction(params) do
    %Directive.RunInstruction{
      instruction: %Jido.Instruction{
        action: Jido.Composer.Orchestrator.LLMAction,
        params: params
      },
      result_action: :orchestrator_llm_result
    }
  end

  defp handle_approval_decision(agent, request_id, response, call) do
    case response.decision do
      :approved ->
        # Remove from gated_calls, dispatch the tool (or queue if at capacity)
        state = StratState.get(agent)

        if ToolConcurrency.at_capacity?(state.tool_concurrency) do
          # At capacity — queue instead of dispatching
          agent =
            StratState.update(agent, fn s ->
              new_ag = ApprovalGate.remove(s.approval_gate, request_id)
              new_tc = ToolConcurrency.enqueue(s.tool_concurrency, call)
              new_status = StatusComputer.compute(new_tc, new_ag, s.suspended_calls)

              %{s | approval_gate: new_ag, tool_concurrency: new_tc, status: new_status}
            end)

          {agent, []}
        else
          agent =
            StratState.update(agent, fn s ->
              new_ag = ApprovalGate.remove(s.approval_gate, request_id)
              new_tc = ToolConcurrency.add_pending(s.tool_concurrency, call.id)
              new_status = StatusComputer.compute(new_tc, new_ag, s.suspended_calls)

              %{s | approval_gate: new_ag, tool_concurrency: new_tc, status: new_status}
            end)

          directive = build_tool_directive(call, state.nodes, state.context)
          {agent, [directive]}
        end

      :rejected ->
        comment = response.comment || "No reason provided"
        handle_approval_rejection(agent, request_id, call, comment)
    end
  end

  defp handle_approval_rejection(agent, request_id, call, reason) do
    state = StratState.get(agent)

    case state.approval_gate.rejection_policy do
      :abort_iteration ->
        agent =
          StratState.update(agent, fn s ->
            %{
              s
              | status: :error,
                result: "Iteration aborted: tool #{call.name} rejected. Reason: #{reason}",
                approval_gate: %{s.approval_gate | gated_calls: %{}},
                tool_concurrency: %{s.tool_concurrency | pending: []}
            }
          end)

        {agent, []}

      :cancel_siblings ->
        # Cancel all pending tool calls with synthetic results
        cancel_results =
          Enum.map(state.tool_concurrency.pending, fn pending_id ->
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
            new_ag = ApprovalGate.remove(s.approval_gate, request_id)
            new_completed = s.tool_concurrency.completed ++ cancel_results ++ [rejection_result]
            new_context = Context.apply_result(s.context, scope_key, rejection_data)

            %{
              s
              | approval_gate: new_ag,
                tool_concurrency: %{s.tool_concurrency | completed: new_completed, pending: []},
                context: new_context
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
            new_ag = ApprovalGate.remove(s.approval_gate, request_id)
            new_completed = s.tool_concurrency.completed ++ [tool_result]
            new_context = Context.apply_result(s.context, scope_key, rejection_data)

            %{
              s
              | approval_gate: new_ag,
                tool_concurrency: %{s.tool_concurrency | completed: new_completed},
                context: new_context
            }
          end)

        check_all_tools_done(agent)
    end
  end

  defp handle_tool_suspension(agent, call_id, tool_name, params) do
    case extract_or_build_suspension(call_id, tool_name, params) do
      {:ok, suspension} ->
        call = %{id: call_id, name: tool_name, arguments: params[:arguments] || %{}}

        agent =
          StratState.update(agent, fn s ->
            new_tc = %{
              s.tool_concurrency
              | pending: List.delete(s.tool_concurrency.pending, call_id)
            }

            new_suspended =
              Map.put(s.suspended_calls, suspension.id, %{suspension: suspension, call: call})

            new_status = StatusComputer.compute(new_tc, s.approval_gate, new_suspended)
            %{s | tool_concurrency: new_tc, suspended_calls: new_suspended, status: new_status}
          end)

        directive = %SuspendDirective{suspension: suspension}
        state = StratState.get(agent)
        directives = Checkpoint.maybe_add_checkpoint_and_stop([directive], state)
        {agent, directives}

      {:error, reason} ->
        # Treat as error result for the tool call
        tool_result = AgentTool.to_tool_result(call_id, tool_name, {:error, reason})
        scope_key = scope_atom(agent, tool_name)

        agent =
          StratState.update(agent, fn s ->
            new_tc = ToolConcurrency.record_result(s.tool_concurrency, call_id, tool_result)
            new_context = Context.apply_result(s.context, scope_key, %{error: reason})

            %{s | tool_concurrency: new_tc, context: new_context}
          end)

        check_all_tools_done(agent)
    end
  end

  defp check_all_tools_done(agent) do
    state = StratState.get(agent)

    case StatusComputer.compute(
           state.tool_concurrency,
           state.approval_gate,
           state.suspended_calls
         ) do
      :awaiting_llm ->
        agent = StratState.update(agent, fn s -> %{s | status: :awaiting_llm} end)
        emit_llm_call(agent)

      new_status ->
        agent = StratState.update(agent, fn s -> %{s | status: new_status} end)
        {agent, []}
    end
  end

  defp dispatch_queued_tool_calls(agent) do
    state = StratState.get(agent)
    {new_tc, to_dispatch} = ToolConcurrency.drain_queue(state.tool_concurrency)

    if to_dispatch == [] do
      {agent, []}
    else
      directives =
        Enum.map(to_dispatch, fn call ->
          build_tool_directive(call, state.nodes, state.context)
        end)

      spawn_phases =
        directives
        |> Enum.filter(&match?(%Directive.SpawnAgent{}, &1))
        |> Map.new(fn %Directive.SpawnAgent{tag: tag} -> {tag, :spawning} end)

      agent =
        StratState.update(agent, fn s ->
          %{
            s
            | tool_concurrency: new_tc,
              children: Children.merge_phases(s.children, spawn_phases)
          }
        end)

      {agent, directives}
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

  # Extract an embedded Suspension from the tool result (runtime DirectiveExec path),
  # or build a new one from explicit params (strategy-level test path).
  defp extract_or_build_suspension(call_id, tool_name, params) do
    result = params[:result]

    embedded =
      case result do
        %{__suspension__: %Suspension{} = s} -> s
        _ -> nil
      end

    if embedded do
      # Enrich the embedded suspension with tool call metadata
      enriched = %{
        embedded
        | resume_signal: embedded.resume_signal || "composer.suspend.resume",
          metadata: Map.merge(embedded.metadata, %{tool_call_id: call_id, tool_name: tool_name})
      }

      {:ok, enriched}
    else
      reason = params[:reason] || :custom
      suspension_meta = params[:suspension_metadata] || %{}

      Suspension.new(
        reason: reason,
        timeout: Map.get(suspension_meta, :timeout, :infinity),
        resume_signal: "composer.suspend.resume",
        metadata: Map.merge(suspension_meta, %{tool_call_id: call_id, tool_name: tool_name})
      )
    end
  end

  # -- Checkpoint hooks --

  @doc """
  Returns replay directives for restoring in-flight operations from checkpoint state.

  Called by `Checkpoint.replay_directives/1` via `function_exported?/3` delegation.
  """
  @spec replay_directives_from_state(map()) :: [struct()]
  def replay_directives_from_state(state) do
    case Map.get(state, :status) do
      :awaiting_llm ->
        replay_awaiting_llm(state)

      status
      when status in [
             :awaiting_tool,
             :awaiting_tools,
             :awaiting_tools_and_approval,
             :awaiting_tools_and_suspension
           ] ->
        replay_awaiting_tools(state)

      _ ->
        []
    end
  end

  defp replay_awaiting_llm(state) do
    tool_results =
      case Map.get(state, :tool_concurrency) do
        %ToolConcurrency{completed: completed} -> completed
        _ -> Map.get(state, :completed_tool_results, [])
      end

    [
      build_llm_instruction(%{
        conversation: Map.get(state, :conversation),
        tool_results: tool_results,
        tools: Map.get(state, :tools, []),
        model: Map.get(state, :model),
        query: Map.get(state, :query),
        system_prompt: Map.get(state, :system_prompt),
        temperature: Map.get(state, :temperature),
        max_tokens: Map.get(state, :max_tokens),
        stream: Map.get(state, :stream, false),
        llm_opts: Map.get(state, :llm_opts, []),
        req_options: Map.get(state, :req_options, [])
      })
    ]
  end

  defp replay_awaiting_tools(state) do
    pending =
      case Map.get(state, :tool_concurrency) do
        %ToolConcurrency{pending: p} -> p
        _ -> Map.get(state, :pending_tool_calls, [])
      end

    nodes = Map.get(state, :nodes, %{})
    context = Map.get(state, :context)
    conversation = Map.get(state, :conversation, [])

    tool_calls_from_conversation =
      conversation
      |> Enum.reverse()
      |> Enum.find_value([], fn
        %{role: "assistant", tool_calls: calls} when is_list(calls) -> calls
        _ -> false
      end)

    pending_set = MapSet.new(pending)

    tool_calls_from_conversation
    |> Enum.filter(fn call -> MapSet.member?(pending_set, call[:id] || call.id) end)
    |> Enum.flat_map(fn call ->
      call = replay_to_tool_call_map(call)
      directive = replay_build_tool_directive(call, nodes, context)
      if directive, do: [directive], else: []
    end)
  end

  defp replay_to_tool_call_map(call) when is_map(call) do
    %{
      id: call[:id] || Map.get(call, "id"),
      name: call[:name] || Map.get(call, "name"),
      arguments: call[:arguments] || Map.get(call, "arguments", %{})
    }
  end

  defp replay_build_tool_directive(call, nodes, %Context{} = ctx) do
    if nodes[call.name], do: build_tool_directive(call, nodes, ctx), else: nil
  end

  defp replay_build_tool_directive(call, _nodes, _ctx) do
    %Directive.RunInstruction{
      instruction: %Jido.Instruction{
        action: :unknown,
        params: %{call_id: call.id, tool_name: call.name}
      },
      result_action: :orchestrator_tool_result,
      meta: %{call_id: call.id, tool_name: call.name}
    }
  end

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

  # -- Termination tool helpers --

  defp build_termination_tool(nil, tools, name_atoms), do: {tools, name_atoms, nil, nil}

  defp build_termination_tool(mod, tools, name_atoms) when is_atom(mod) do
    tool = AgentTool.to_tool(mod)
    name = mod.name()
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    updated_atoms = Map.put(name_atoms, name, String.to_atom(name))
    {tools ++ [tool], updated_atoms, name, mod}
  end

  defp find_termination_call(_calls, nil), do: :not_terminated

  defp find_termination_call(calls, term_name) do
    case Enum.find(calls, &(&1.name == term_name)) do
      nil -> :not_terminated
      call -> {:terminated, call}
    end
  end

  defp handle_termination(agent, call, state) do
    args = AgentTool.to_context(call)

    case Jido.Exec.run(state.termination_tool_mod, args, %{}) do
      {:ok, result} ->
        agent =
          StratState.update(agent, fn s ->
            %{s | status: :completed, result: NodeIO.object(result)}
          end)

        {agent, []}

      {:error, reason} ->
        tool_result = AgentTool.to_tool_result(call.id, call.name, {:error, reason})

        agent =
          StratState.update(agent, fn s ->
            %{s | tool_concurrency: %{s.tool_concurrency | completed: [tool_result], pending: []}}
          end)

        emit_llm_call(agent)
    end
  end
end
