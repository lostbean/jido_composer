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
  alias Jido.Composer.Node.ActionNode
  alias Jido.Composer.Node.AgentNode
  alias Jido.Composer.Orchestrator.AgentTool

  # -- init/2 --

  @impl true
  def init(agent, ctx) do
    opts = ctx.strategy_opts

    node_modules = opts[:nodes] || []
    nodes = build_nodes(node_modules)
    tools = Enum.map(nodes, fn {_name, node} -> AgentTool.to_tool(node) end)

    agent =
      StratState.put(agent, %{
        module: __MODULE__,
        status: :idle,
        nodes: nodes,
        llm_module: opts[:llm_module],
        system_prompt: opts[:system_prompt],
        conversation: nil,
        tools: tools,
        pending_tool_calls: [],
        completed_tool_results: [],
        context: %{},
        iteration: 0,
        max_iterations: opts[:max_iterations] || 10,
        req_options: opts[:req_options] || [],
        result: nil,
        query: nil
      })

    {agent, []}
  end

  # -- cmd/3 --

  @impl true
  def cmd(agent, [%Jido.Instruction{action: :orchestrator_start} = instr | _], _ctx) do
    query = instr.params[:query] || instr.params["query"]

    agent =
      StratState.update(agent, fn s ->
        %{s | status: :awaiting_llm, query: query, iteration: 0}
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

    tool_result =
      case params[:status] do
        :ok ->
          AgentTool.to_tool_result(call_id, tool_name, {:ok, params[:result]})

        :error ->
          AgentTool.to_tool_result(call_id, tool_name, {:error, params[:result]})
      end

    # Scope result under tool name in context (only on success)
    scope_key = String.to_existing_atom(tool_name)

    scoped_result =
      case params[:status] do
        :ok -> params[:result] || %{}
        :error -> %{error: inspect(params[:result])}
      end

    agent =
      StratState.update(agent, fn s ->
        new_pending = List.delete(s.pending_tool_calls, call_id)
        new_completed = s.completed_tool_results ++ [tool_result]
        new_context = deep_merge(s.context, %{scope_key => scoped_result})

        %{
          s
          | pending_tool_calls: new_pending,
            completed_tool_results: new_completed,
            context: new_context
        }
      end)

    state = StratState.get(agent)

    if state.pending_tool_calls == [] do
      # All tools done, trigger next LLM call
      agent = StratState.update(agent, fn s -> %{s | status: :awaiting_llm} end)
      emit_llm_call(agent)
    else
      {agent, []}
    end
  end

  def cmd(agent, [%Jido.Instruction{action: :orchestrator_child_started} | _], _ctx) do
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

    scope_key = String.to_existing_atom(tool_name)

    scoped_result =
      case status do
        :ok -> result || %{}
        :error -> %{error: inspect(result)}
      end

    agent =
      StratState.update(agent, fn s ->
        new_pending = List.delete(s.pending_tool_calls, call_id)
        new_completed = s.completed_tool_results ++ [tool_result]
        new_context = deep_merge(s.context, %{scope_key => scoped_result})

        %{
          s
          | pending_tool_calls: new_pending,
            completed_tool_results: new_completed,
            context: new_context
        }
      end)

    state = StratState.get(agent)

    if state.pending_tool_calls == [] do
      agent = StratState.update(agent, fn s -> %{s | status: :awaiting_llm} end)
      emit_llm_call(agent)
    else
      {agent, []}
    end
  end

  def cmd(agent, [%Jido.Instruction{action: :orchestrator_child_exit} | _], _ctx) do
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
      {"jido.agent.child.exit", {:strategy_cmd, :orchestrator_child_exit}}
    ]
  end

  # -- snapshot/2 --

  @impl true
  def snapshot(agent, _ctx) do
    strat = StratState.get(agent, %{})
    status = Map.get(strat, :status, :idle)

    %Jido.Agent.Strategy.Snapshot{
      status: status,
      done?: status in [:completed, :error],
      result: Map.get(strat, :result),
      details: %{
        iteration: Map.get(strat, :iteration, 0),
        context: Map.get(strat, :context, %{})
      }
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
            %{s | status: :completed, result: text}
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
      call_ids = Enum.map(calls, & &1.id)

      agent =
        StratState.update(agent, fn s ->
          %{s | status: :awaiting_tools, pending_tool_calls: call_ids, completed_tool_results: []}
        end)

      directives =
        Enum.map(calls, fn call ->
          node = state.nodes[call.name]
          context = AgentTool.to_context(call)

          case node do
            %ActionNode{action_module: action_module} ->
              instruction = %Jido.Instruction{
                action: action_module,
                params: context
              }

              %Directive.RunInstruction{
                instruction: instruction,
                result_action: :orchestrator_tool_result,
                meta: %{call_id: call.id, tool_name: call.name}
              }

            %AgentNode{agent_module: agent_module, opts: opts} ->
              %Directive.SpawnAgent{
                tag: {:tool_call, call.id, call.name},
                agent: agent_module,
                opts: Map.new(opts) |> Map.put(:context, context)
              }
          end
        end)

      {agent, directives}
    end
  end

  defp emit_llm_call(agent) do
    state = StratState.get(agent)

    # Build an internal instruction for the LLM call
    instruction = %Jido.Instruction{
      action: Jido.Composer.Orchestrator.LLMAction,
      params: %{
        llm_module: state.llm_module,
        conversation: state.conversation,
        tool_results: state.completed_tool_results,
        tools: state.tools,
        opts: [
          query: state.query,
          system_prompt: state.system_prompt,
          req_options: state.req_options
        ]
      }
    }

    directive = %Directive.RunInstruction{
      instruction: instruction,
      result_action: :orchestrator_llm_result
    }

    {agent, [directive]}
  end

  defp build_nodes(modules) when is_list(modules) do
    Map.new(modules, fn
      mod when is_atom(mod) ->
        if agent_module?(mod) do
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

  defp agent_module?(module) do
    Code.ensure_loaded?(module) && function_exported?(module, :__agent_metadata__, 0)
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn
      _key, left_val, right_val when is_map(left_val) and is_map(right_val) ->
        deep_merge(left_val, right_val)

      _key, _left_val, right_val ->
        right_val
    end)
  end
end
