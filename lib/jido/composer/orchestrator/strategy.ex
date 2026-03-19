defmodule Jido.Composer.Orchestrator.Strategy do
  @moduledoc """
  Jido.Agent.Strategy implementation for LLM-driven orchestration.

  Implements a ReAct-style (Reason + Act) loop: call LLM, execute tool calls,
  feed results back, repeat until final answer or iteration limit.

  All side effects are dispatched via directives — the strategy itself is pure.

  ## Error Handling

  Error reasons are stored as structured data in `strat.result` (not stringified
  via `inspect/1`), preserving error types for callers that pattern-match on them.
  LLM-facing error context (tool results, conversation messages) continues to use
  string representations since the LLM consumes text.

  All error paths close open observability spans (agent, iteration) to ensure
  telemetry is emitted even on failure.
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
  alias Jido.Composer.Orchestrator.Obs
  alias Jido.Composer.Orchestrator.StatusComputer
  alias Jido.Composer.OtelCtx
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
      |> Map.put(:schema_keys, extract_all_schema_keys(nodes))
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

    schema_keys = extract_all_schema_keys(nodes)

    {tools, name_atoms, term_name, term_mod} =
      build_termination_tool(opts[:termination_tool], tools, name_atoms)

    agent =
      StratState.put(agent, %{
        module: __MODULE__,
        status: :idle,
        nodes: nodes,
        schema_keys: schema_keys,
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
        termination_tool_mod: term_mod,
        _obs: Obs.new()
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

    agent =
      update_obs(agent, &Obs.start_agent_span(&1, %{query: query, name: Obs.agent_name(agent)}))

    emit_llm_call(agent)
  end

  def cmd(agent, [%Jido.Instruction{action: :orchestrator_llm_result} = instr | _], _ctx) do
    params = instr.params

    llm_measurements = Obs.build_llm_measurements(params)
    agent = update_obs(agent, &Obs.accumulate_tokens(&1, llm_measurements))
    agent = update_obs(agent, &Obs.finish_llm_span(&1, llm_measurements))

    case params do
      %{status: :ok, result: %{response: response, conversation: conversation} = result} ->
        handle_llm_response(agent, response, conversation, result[:finish_reason])

      %{status: :error, result: %{error: reason}} ->
        agent =
          StratState.update(agent, fn s ->
            %{s | status: :error, result: reason}
          end)

        agent = finish_agent_span(agent, %{error: reason})
        {agent, []}

      _ ->
        agent =
          StratState.update(agent, fn s ->
            %{s | status: :error, result: "unexpected LLM result format"}
          end)

        agent = finish_agent_span(agent, %{error: "unexpected LLM result format"})
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
        # Check if tool signaled suspension via effects or outcome
        cond do
          status == :ok and :suspend in List.wrap(params[:effects]) ->
            handle_tool_suspension(agent, call_id, tool_name, params)

          status == :ok and params[:outcome] == :suspend ->
            handle_tool_suspension(agent, call_id, tool_name, params)

          true ->
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

            agent = finish_tool_span(agent, call_id, tool_name, params[:result], status)

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

    # Strip the Context ambient marker key from child result — it's a tuple that
    # can't be serialized to JSON for the LLM conversation.
    result =
      if is_map(result),
        do: Map.delete(result, Jido.Composer.Context.ambient_key()),
        else: result

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

    agent = finish_tool_span(agent, call_id, tool_name, result, status)

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

  # Generalized suspend resume for orchestrator tool calls and approval gate
  def cmd(agent, [%Jido.Instruction{action: :suspend_resume} = instr | _], _ctx) do
    strat = StratState.get(agent)
    params = instr.params
    suspension_id = params[:suspension_id]

    cond do
      # Priority 1: Suspended tool call
      Map.has_key?(strat.suspended_calls, suspension_id) ->
        %{call: call} = Map.get(strat.suspended_calls, suspension_id)
        outcome = params[:outcome] || :ok
        data = params[:data]

        if outcome == :ok and data != nil do
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
          agent =
            StratState.update(agent, fn s ->
              new_suspended = Map.delete(s.suspended_calls, suspension_id)
              new_tc = ToolConcurrency.add_pending(s.tool_concurrency, call.id)
              %{s | suspended_calls: new_suspended, tool_concurrency: new_tc}
            end)

          state = StratState.get(agent)

          directive =
            build_tool_directive(call, state.nodes, state.context, schema_keys: state.schema_keys)

          {agent, [directive]}
        end

      # Priority 2: Approval gate entry
      ApprovalGate.get(strat.approval_gate, suspension_id) != nil ->
        handle_approval_resume(agent, strat, suspension_id, params)

      # Priority 3: No match
      true ->
        {agent,
         [
           %Directive.Error{
             error: %RuntimeError{message: "No suspended call for #{inspect(suspension_id)}"}
           }
         ]}
    end
  end

  # Generalized suspend timeout for orchestrator
  def cmd(agent, [%Jido.Instruction{action: :suspend_timeout} = instr | _], _ctx) do
    strat = StratState.get(agent)
    suspension_id = instr.params[:suspension_id]

    cond do
      Map.has_key?(strat.suspended_calls, suspension_id) ->
        %{call: call} = Map.get(strat.suspended_calls, suspension_id)

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

      ApprovalGate.get(strat.approval_gate, suspension_id) != nil ->
        %{call: call} = ApprovalGate.get(strat.approval_gate, suspension_id)
        handle_approval_rejection(agent, suspension_id, call, "Approval timed out")

      true ->
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

  defp handle_llm_response(agent, response, conversation, finish_reason) do
    agent =
      StratState.update(agent, fn s ->
        %{s | conversation: conversation, iteration: s.iteration + 1}
      end)

    state = StratState.get(agent)

    if finish_reason == :length do
      require Logger

      Logger.error("LLM response truncated (finish_reason: :length), failing fast",
        iteration: state.iteration,
        query: state.query
      )

      agent =
        StratState.update(agent, fn s ->
          %{
            s
            | status: :error,
              result:
                "LLM response truncated (finish_reason: :length) — increase max_tokens or reduce prompt size"
          }
        end)

      agent = update_obs(agent, &Obs.finish_iteration_span(&1, %{error: "truncated"}))
      agent = finish_agent_span(agent, %{error: "truncated"})
      {agent, []}
    else
      handle_llm_response_by_type(agent, response, state)
    end
  end

  defp handle_llm_response_by_type(agent, response, state) do
    case response do
      {:final_answer, text} ->
        agent =
          StratState.update(agent, fn s ->
            %{s | status: :completed, result: NodeIO.text(text)}
          end)

        agent =
          update_obs(
            agent,
            &Obs.finish_iteration_span(&1, %{
              output: "final_answer: #{String.slice(text, 0..100)}"
            })
          )

        agent = finish_agent_span(agent)
        {agent, []}

      {:tool_calls, calls} ->
        dispatch_tool_calls(agent, calls, state)

      {:tool_calls, calls, _reasoning} ->
        dispatch_tool_calls(agent, calls, state)

      {:error, reason} ->
        agent =
          StratState.update(agent, fn s ->
            %{s | status: :error, result: reason}
          end)

        agent = update_obs(agent, &Obs.finish_iteration_span(&1, %{error: reason}))
        agent = finish_agent_span(agent, %{error: reason})
        {agent, []}
    end
  end

  defp dispatch_tool_calls(agent, calls, state) do
    if state.iteration >= state.max_iterations do
      error = "max iteration limit reached (#{state.max_iterations})"

      agent =
        StratState.update(agent, fn s ->
          %{s | status: :error, result: error}
        end)

      agent = update_obs(agent, &Obs.finish_iteration_span(&1, %{error: error}))
      agent = finish_agent_span(agent, %{error: error})
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
        error = "Failed to create approval request: #{reason}"

        agent =
          StratState.update(agent, fn s ->
            %{s | status: :error, result: error}
          end)

        agent = update_obs(agent, &Obs.finish_iteration_span(&1, %{error: error}))
        agent = finish_agent_span(agent, %{error: error})
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

        # Start tool spans and capture OTel context for AgentNode child propagation.
        {agent, otel_ctx_by_call} =
          start_tool_spans_with_ctx(agent, to_dispatch, state.nodes)

        # Build directives for dispatched (ungated, within concurrency limit) calls
        ungated_directives =
          Enum.map(to_dispatch, fn call ->
            otel_ctx = Map.get(otel_ctx_by_call, call.id)

            build_tool_directive(call, state.nodes, state.context,
              schema_keys: state.schema_keys,
              otel_parent_ctx: otel_ctx
            )
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

  defp build_tool_directive(call, nodes, ctx, opts \\ [])

  defp build_tool_directive(call, nodes, %Context{} = ctx, opts) do
    schema_keys = Keyword.get(opts, :schema_keys)
    otel_parent_ctx = Keyword.get(opts, :otel_parent_ctx)

    keys_for_call =
      case schema_keys do
        %{} ->
          case Map.get(schema_keys, call.name) do
            %MapSet{} = s -> if MapSet.size(s) == 0, do: nil, else: s
            _ -> nil
          end

        _ ->
          nil
      end

    tool_args = AgentTool.to_context(call, keys_for_call)
    node = Map.get(nodes, call.name)

    # ActionNode gets tool args merged into context; AgentNode handles via :tool_args opt
    flat_context =
      case node do
        %ActionNode{} ->
          clean_ctx = %{ctx | working: tool_args}
          Context.to_flat_map(clean_ctx)

        _ ->
          Context.to_flat_map(ctx)
      end

    opts = [
      result_action: :orchestrator_tool_result,
      meta: %{call_id: call.id, tool_name: call.name},
      tag: {:tool_call, call.id, call.name},
      structured_context: ctx,
      tool_args: tool_args,
      otel_parent_ctx: otel_parent_ctx
    ]

    {:ok, [directive | _]} = node.__struct__.to_directive(node, flat_context, opts)
    directive
  end

  defp emit_llm_call(agent) do
    state = StratState.get(agent)

    agent =
      update_obs(
        agent,
        &Obs.start_iteration_span(&1, %{
          iteration: state.iteration + 1,
          input: Obs.summarize_conversation(state)
        })
      )

    input_messages =
      case Obs.extract_input_messages(state.conversation) do
        nil ->
          system =
            if state.system_prompt,
              do: [%{role: "system", content: state.system_prompt}],
              else: []

          system ++ [%{role: "user", content: state.query || ""}]

        [] ->
          system =
            if state.system_prompt,
              do: [%{role: "system", content: state.system_prompt}],
              else: []

          system ++ [%{role: "user", content: state.query || ""}]

        msgs ->
          msgs
      end

    # Append pending tool results that LLMAction will add to the conversation.
    # Without this, the LLM span's input_messages would be missing the most
    # recent tool results (they only enter the conversation inside LLMAction).
    input_messages =
      Enum.reduce(state.tool_concurrency.completed, input_messages, fn tr, acc ->
        acc ++ [%{role: "tool", content: Jason.encode!(tr.result)}]
      end)

    agent =
      update_obs(
        agent,
        &Obs.start_llm_span(&1, %{
          model: state.model,
          iteration: state.iteration + 1,
          input_messages: input_messages
        })
      )

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

  defp handle_approval_resume(agent, strat, request_id, params) do
    %{request: request, call: call} = ApprovalGate.get(strat.approval_gate, request_id)
    response_data = params[:response_data] || params

    case ApprovalResponse.new(
           request_id: response_data[:request_id] || request_id,
           decision: response_data[:decision],
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

  defp handle_approval_decision(agent, request_id, response, call) do
    case response.decision do
      :approved ->
        # Remove from gated_calls, dispatch the tool (or queue if at capacity)
        state = StratState.get(agent)

        if ToolConcurrency.at_capacity?(state.tool_concurrency) do
          # At capacity — queue instead of dispatching
          case ToolConcurrency.enqueue(state.tool_concurrency, call) do
            {:ok, new_tc} ->
              agent =
                StratState.update(agent, fn s ->
                  new_ag = ApprovalGate.remove(s.approval_gate, request_id)
                  new_status = StatusComputer.compute(new_tc, new_ag, s.suspended_calls)

                  %{s | approval_gate: new_ag, tool_concurrency: new_tc, status: new_status}
                end)

              {agent, []}

            {:error, :queue_full} ->
              tool_result =
                AgentTool.to_tool_result(call.id, call.name, {:error, "Tool queue is full"})

              agent =
                StratState.update(agent, fn s ->
                  new_ag = ApprovalGate.remove(s.approval_gate, request_id)

                  new_tc = %{
                    s.tool_concurrency
                    | completed: s.tool_concurrency.completed ++ [tool_result]
                  }

                  new_status = StatusComputer.compute(new_tc, new_ag, s.suspended_calls)
                  %{s | approval_gate: new_ag, tool_concurrency: new_tc, status: new_status}
                end)

              check_all_tools_done(agent)
          end
        else
          agent =
            StratState.update(agent, fn s ->
              new_ag = ApprovalGate.remove(s.approval_gate, request_id)
              new_tc = ToolConcurrency.add_pending(s.tool_concurrency, call.id)
              new_status = StatusComputer.compute(new_tc, new_ag, s.suspended_calls)

              %{s | approval_gate: new_ag, tool_concurrency: new_tc, status: new_status}
            end)

          directive =
            build_tool_directive(call, state.nodes, state.context, schema_keys: state.schema_keys)

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
        error = "Iteration aborted: tool #{call.name} rejected. Reason: #{reason}"

        agent =
          StratState.update(agent, fn s ->
            %{
              s
              | status: :error,
                result: error,
                approval_gate: %{s.approval_gate | gated_calls: %{}},
                tool_concurrency: %{s.tool_concurrency | pending: []}
            }
          end)

        agent = finish_agent_span(agent, %{error: error})
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
        agent =
          update_obs(
            agent,
            &Obs.finish_iteration_span(&1, %{output: "tools_done, next_iteration"})
          )

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
          build_tool_directive(call, state.nodes, state.context, schema_keys: state.schema_keys)
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
    if Map.get(nodes, call.name), do: build_tool_directive(call, nodes, ctx), else: nil
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

  @doc """
  Strategy-specific closure stripping for checkpoint serialization.

  Called by `Checkpoint.prepare_for_checkpoint/1` via delegation.
  Strips closures from nested structures (e.g., `approval_gate.approval_policy`)
  in addition to top-level function values.
  """
  @spec strip_for_checkpoint(map()) :: map()
  def strip_for_checkpoint(state) do
    Map.new(state, fn
      {:approval_gate, %{approval_policy: _} = gate} ->
        {:approval_gate, %{gate | approval_policy: nil}}

      {:_obs, _} ->
        {:_obs, Obs.new()}

      {k, v} when is_function(v) ->
        {k, nil}

      kv ->
        kv
    end)
  end

  @doc false
  def reattach_runtime_config(agent, strategy_opts) do
    strat = StratState.get(agent)
    restored = Checkpoint.reattach_runtime_config(strat, strategy_opts)
    StratState.put(agent, restored)
  end

  # -- Observability helpers (delegate to Obs struct) --

  defp update_obs(agent, fun) do
    StratState.update(agent, fn s -> %{s | _obs: fun.(s._obs)} end)
  end

  defp finish_agent_span(agent, extra \\ %{}) do
    state = StratState.get(agent)
    obs = Obs.finish_agent_span(state._obs, state, extra)
    StratState.update(agent, fn s -> %{s | _obs: obs} end)
  end

  defp finish_tool_span(agent, call_id, tool_name, result, status) do
    measurements = %{tool_name: tool_name, result: result, status: status}

    measurements =
      if status == :error,
        do: Map.put(measurements, :error, result),
        else: measurements

    update_obs(agent, &Obs.finish_tool_span(&1, call_id, measurements))
  end

  # Start tool spans for dispatched calls, saving/restoring OTel context so
  # sibling spans don't nest under each other. For AgentNode calls, captures
  # the tool span's OTel context for child process propagation.
  defp start_tool_spans_with_ctx(agent, to_dispatch, nodes) do
    Enum.reduce(to_dispatch, {agent, %{}}, fn call, {ag, ctx_map} ->
      saved_ctx = OtelCtx.get_current()
      ag = update_obs(ag, &Obs.start_tool_span(&1, call))

      is_agent_node = match?(%AgentNode{}, Map.get(nodes, call.name))

      ctx_map =
        if is_agent_node do
          case OtelCtx.get_current() do
            nil -> ctx_map
            ctx -> Map.put(ctx_map, call.id, ctx)
          end
        else
          ctx_map
        end

      OtelCtx.attach(saved_ctx)
      {ag, ctx_map}
    end)
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

    # If parent sent ambient data (from Context.to_flat_map), merge it
    {inherited_ambient, params} =
      case Map.pop(params, Context.ambient_key()) do
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

    tools =
      if Enum.any?(tools, fn t -> t.name == tool.name end) do
        tools
      else
        tools ++ [tool]
      end

    {tools, updated_atoms, name, mod}
  end

  defp find_termination_call(_calls, nil), do: :not_terminated

  defp find_termination_call(calls, term_name) do
    case Enum.find(calls, &(&1.name == term_name)) do
      nil -> :not_terminated
      call -> {:terminated, call}
    end
  end

  defp handle_termination(agent, call, state) do
    term_keys =
      case Map.get(state, :schema_keys, %{})[call.name] do
        %MapSet{} = s -> if MapSet.size(s) == 0, do: nil, else: s
        _ -> nil
      end

    args = AgentTool.to_context(call, term_keys)
    flat_params = Context.to_flat_map(%{state.context | working: args})

    case Jido.Exec.run(state.termination_tool_mod, flat_params, %{}) do
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

  defp extract_all_schema_keys(nodes) do
    Map.new(nodes, fn {name, node} ->
      schema = node.__struct__.schema(node)

      keys =
        case schema do
          list when is_list(list) ->
            Enum.map(list, fn
              {key, _opts} when is_atom(key) -> key
              key when is_atom(key) -> key
            end)
            |> MapSet.new()

          _ ->
            MapSet.new()
        end

      {name, keys}
    end)
  end
end
