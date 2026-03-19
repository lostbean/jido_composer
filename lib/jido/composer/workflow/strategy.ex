defmodule Jido.Composer.Workflow.Strategy do
  @moduledoc """
  Jido.Agent.Strategy implementation for deterministic FSM-based workflows.

  Drives a `Jido.Composer.Workflow.Machine` through its states by emitting
  directives. Keeps `cmd/3` pure — no side effects.

  ## Error Propagation

  The strategy preserves original error reasons via the `error_reason` field in
  strategy state. When a node fails, the actual error (action error struct,
  child agent error, or transition error) is stored and threaded through to
  observability spans and the DSL's `check_terminal` function. Callers receive
  the original error rather than a generic `:workflow_failed` atom.

  Every path that sets `status: :failure` also closes the agent observability
  span, ensuring telemetry is emitted on all failure scenarios.
  """

  use Jido.Agent.Strategy

  require Logger

  alias Jido.Agent.Directive
  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.Composer.Checkpoint
  alias Jido.Composer.Children
  alias Jido.Composer.Context
  alias Jido.Composer.Directive.Suspend, as: SuspendDirective
  alias Jido.Composer.FanOut.State, as: FanOutState
  alias Jido.Composer.HITL.{ApprovalRequest, ApprovalResponse}
  alias Jido.Composer.Node.ActionNode
  alias Jido.Composer.Node.AgentNode
  alias Jido.Composer.Node.FanOutNode
  alias Jido.Composer.Node.HumanNode
  alias Jido.Composer.Suspension
  alias Jido.Composer.Workflow.Machine
  alias Jido.Composer.Workflow.Obs
  alias Jido.Composer.OtelCtx

  # -- init/2 --

  @impl true
  def init(agent, ctx) do
    opts = ctx.strategy_opts
    existing = StratState.get(agent, %{})

    if Map.get(existing, :module) == __MODULE__ and Map.get(existing, :status) != :idle do
      # Restored agent — keep checkpoint state, no rebuild needed
      {agent, []}
    else
      fresh_init(agent, ctx, opts)
    end
  end

  defp fresh_init(agent, ctx, opts) do
    nodes = build_nodes(opts[:nodes])

    machine =
      Machine.new(
        nodes: nodes,
        transitions: opts[:transitions],
        initial: opts[:initial],
        terminal_states: opts[:terminal_states] || [:done, :failed]
      )

    agent =
      StratState.put(agent, %{
        module: __MODULE__,
        status: :idle,
        error_reason: nil,
        machine: machine,
        pending_child: nil,
        child_request_id: nil,
        pending_suspension: nil,
        fan_out: nil,
        ambient_keys: opts[:ambient] || [],
        fork_fns: opts[:fork_fns] || %{},
        children: Children.new(),
        hibernate_after: opts[:hibernate_after],
        agent_id: agent.id,
        agent_module: ctx[:agent_module],
        success_states: opts[:success_states] || [:done],
        _obs: Obs.new()
      })

    {agent, []}
  end

  # -- cmd/3 --

  @impl true
  def cmd(agent, [%Jido.Instruction{action: :workflow_start} = instr | _rest], _ctx) do
    agent = StratState.set_status(agent, :running)
    strat = StratState.get(agent)
    params = instr.params || %{}

    # Build Context from params: extract ambient keys, remaining go to working
    context = build_start_context(strat.machine.context, params, strat)
    machine = %{strat.machine | context: context}
    agent = put_machine(agent, machine)

    maybe_reattach_parent_otel_ctx(agent)
    agent = update_obs(agent, &Obs.start_agent_span(&1, %{name: Obs.agent_name(agent)}))
    dispatch_current_node(agent)
  end

  def cmd(agent, [%Jido.Instruction{action: :workflow_node_result} = instr | _rest], _ctx) do
    strat = StratState.get(agent)
    params = instr.params

    node_measurements =
      case params do
        %{status: :ok, result: result} ->
          %{result: result}

        %{status: :error, result: result} ->
          %{error: (is_map(result) && result[:error]) || result || "node execution failed"}

        %{status: :error} ->
          %{error: "node execution failed"}

        _ ->
          %{}
      end

    agent = update_obs(agent, &Obs.finish_node_span(&1, node_measurements))

    case params do
      %{status: :ok, result: result, outcome: :suspend} ->
        handle_node_suspend(agent, result, strat)

      %{status: :ok, result: result} ->
        outcome = Map.get(params, :outcome, :ok)
        machine = Machine.apply_result(strat.machine, result)

        case Machine.transition(machine, outcome) do
          {:ok, machine} ->
            agent = put_machine(agent, machine)
            handle_after_transition(agent)

          {:error, reason} ->
            agent = put_machine(agent, machine)
            {fail_with_span(agent, reason), []}
        end

      %{status: :error} ->
        error_reason =
          get_in(params, [:result, :error]) || params[:result] || :node_execution_failed

        machine = strat.machine

        case Machine.transition(machine, :error) do
          {:ok, machine} ->
            agent = put_machine(agent, machine)
            agent = put_error_reason(agent, error_reason)
            handle_after_transition(agent)

          {:error, _reason} ->
            {fail_with_span(agent, error_reason), []}
        end
    end
  end

  def cmd(agent, [%Jido.Instruction{action: :workflow_child_started} = instr | _rest], _ctx) do
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

  def cmd(agent, [%Jido.Instruction{action: :workflow_child_result} = instr | _rest], _ctx) do
    strat = StratState.get(agent)
    params = instr.params
    tag = params[:tag] || strat.machine.status

    agent =
      StratState.update(agent, fn s ->
        %{s | children: Children.record_result(s.children, tag)}
      end)

    case params do
      %{result: {:ok, result}} ->
        # Strip the Context ambient marker key — it's a tuple that can't be serialized
        result =
          if is_map(result),
            do: Map.delete(result, Jido.Composer.Context.ambient_key()),
            else: result

        machine = Machine.apply_result(strat.machine, result)

        case Machine.transition(machine, :ok) do
          {:ok, machine} ->
            agent = put_machine(agent, machine)
            handle_after_transition(agent)

          {:error, reason} ->
            agent = put_machine(agent, machine)
            {fail_with_span(agent, reason), []}
        end

      %{result: {:error, reason}} ->
        case Machine.transition(strat.machine, :error) do
          {:ok, machine} ->
            agent = put_machine(agent, machine)
            agent = put_error_reason(agent, reason)
            handle_after_transition(agent)

          {:error, _reason} ->
            {fail_with_span(agent, reason), []}
        end
    end
  end

  def cmd(agent, [%Jido.Instruction{action: :workflow_child_exit} = instr | _rest], _ctx) do
    params = instr.params
    tag = params[:tag]

    agent =
      StratState.update(agent, fn s ->
        %{s | children: Children.record_exit(s.children, tag, params[:reason])}
      end)

    {agent, []}
  end

  def cmd(agent, [%Jido.Instruction{action: :fan_out_branch_result} = instr | _rest], _ctx) do
    strat = StratState.get(agent)
    params = instr.params
    branch_name = params[:branch_name]
    result = params[:result]
    fan_out = strat.fan_out

    if is_nil(fan_out) do
      {agent, []}
    else
      handle_fan_out_branch_result(agent, fan_out, branch_name, result, strat)
    end
  end

  # Generalized suspend resume
  def cmd(agent, [%Jido.Instruction{action: :suspend_resume} = instr | _rest], _ctx) do
    strat = StratState.get(agent)
    params = instr.params
    suspension_id = params[:suspension_id]

    cond do
      # Priority 1: Single-node suspension with matching ID
      match?(%Suspension{id: ^suspension_id}, strat.pending_suspension) ->
        suspension = strat.pending_suspension

        case suspension.reason do
          :human_input ->
            handle_hitl_resume(agent, suspension, params)

          _other ->
            handle_generic_resume(agent, params)
        end

      # Priority 1b: Single-node suspension exists but ID mismatches
      not is_nil(strat.pending_suspension) ->
        id = strat.pending_suspension.id

        {agent,
         [
           %Directive.Error{
             error: %RuntimeError{
               message:
                 "Suspension ID mismatch: expected #{inspect(id)}, got #{inspect(suspension_id)}"
             }
           }
         ]}

      # Priority 2: Fan-out branch suspension
      has_suspended_fan_out_branch?(strat, suspension_id) ->
        handle_fan_out_branch_resume(agent, strat, suspension_id, params)

      # Priority 3: No match
      true ->
        {agent, [%Directive.Error{error: %RuntimeError{message: "No pending suspension"}}]}
    end
  end

  # Generalized suspend timeout
  def cmd(agent, [%Jido.Instruction{action: :suspend_timeout} = instr | _rest], _ctx) do
    strat = StratState.get(agent)
    suspension_id = instr.params[:suspension_id]

    cond do
      match?(%Suspension{id: ^suspension_id}, strat.pending_suspension) ->
        suspension = strat.pending_suspension
        timeout_outcome = suspension.timeout_outcome

        agent =
          StratState.update(agent, fn s ->
            %{s | status: :running, pending_suspension: nil}
          end)

        strat = StratState.get(agent)

        case Machine.transition(strat.machine, timeout_outcome) do
          {:ok, machine} ->
            agent = put_machine(agent, machine)
            handle_after_transition(agent)

          {:error, reason} ->
            {fail_with_span(agent, reason), []}
        end

      has_suspended_fan_out_branch?(strat, suspension_id) ->
        handle_fan_out_branch_timeout(agent, strat, suspension_id)

      true ->
        {agent, []}
    end
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
      {"composer.workflow.start", {:strategy_cmd, :workflow_start}},
      {"composer.workflow.child.result", {:strategy_cmd, :workflow_child_result}},
      {"jido.agent.child.started", {:strategy_cmd, :workflow_child_started}},
      {"jido.agent.child.exit", {:strategy_cmd, :workflow_child_exit}},
      {"composer.fan_out.branch_result", {:strategy_cmd, :fan_out_branch_result}},
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
      state: get_in(strat, [:machine, Access.key(:status)])
    }

    details =
      case Map.get(strat, :pending_suspension) do
        %Suspension{reason: :human_input, approval_request: %ApprovalRequest{} = request} ->
          Map.merge(details, %{
            reason: :awaiting_approval,
            request_id: request.id,
            node_name: request.node_name
          })

        %Suspension{} = suspension ->
          Map.merge(details, %{
            reason: suspension.reason,
            suspension_id: suspension.id
          })

        _ ->
          details
      end

    details =
      case Map.get(strat, :fan_out) do
        %{suspended_branches: branches} when is_map(branches) and branches != %{} ->
          completed_count =
            case Map.get(strat, :fan_out) do
              %{completed_results: cr} -> map_size(cr)
              _ -> 0
            end

          Map.merge(details, %{
            reason: :fan_out_suspended,
            suspended_branches:
              Enum.map(branches, fn {name, %{suspension: s}} ->
                %{branch: name, suspension_id: s.id, reason: s.reason}
              end),
            completed_count: completed_count,
            total_branches: completed_count + map_size(branches)
          })

        _ ->
          details
      end

    raw_context = get_in(strat, [:machine, Access.key(:context)])

    snapshot_result =
      case raw_context do
        %Context{} -> Context.to_clean_map(raw_context)
        other -> other
      end

    %Jido.Agent.Strategy.Snapshot{
      status: status,
      done?: status in [:success, :failure],
      result: snapshot_result,
      details: details
    }
  end

  # -- Private --

  defp handle_after_transition(agent) do
    strat = StratState.get(agent)

    if Machine.terminal?(strat.machine) do
      success_states = Map.get(strat, :success_states, [:done])
      status = if strat.machine.status in success_states, do: :success, else: :failure
      agent = StratState.set_status(agent, status)

      # When no explicit error_reason was captured, use the terminal state atom
      agent =
        if status == :failure and is_nil(Map.get(strat, :error_reason)) do
          StratState.update(agent, fn s -> Map.put(s, :error_reason, strat.machine.status) end)
        else
          agent
        end

      strat = StratState.get(agent)

      extra =
        if status == :failure do
          case Map.get(strat, :error_reason) do
            nil -> %{}
            er -> %{error: er}
          end
        else
          %{}
        end

      agent = finish_agent_span(agent, extra)
      {agent, []}
    else
      dispatch_current_node(agent)
    end
  end

  defp dispatch_current_node(agent) do
    strat = StratState.get(agent)
    node = Machine.current_node(strat.machine)

    if is_nil(node) do
      {agent, []}
    else
      node_name = node.__struct__.name(node)
      flat_context = Context.to_flat_map(strat.machine.context)
      obs_arguments = Context.to_clean_map(strat.machine.context)

      agent =
        update_obs(
          agent,
          &Obs.start_node_span(&1, %{
            node_name: node_name,
            name: node_name,
            state: strat.machine.status,
            arguments: obs_arguments
          })
        )

      opts = build_node_dispatch_opts(node, strat)

      case node.__struct__.to_directive(node, flat_context, opts) do
        {:ok, directives} ->
          {agent, directives}

        {:ok, directives, side_effects} ->
          agent = apply_node_side_effects(agent, node, side_effects)
          {agent, directives}
      end
    end
  end

  defp build_node_dispatch_opts(node, strat) do
    base = [result_action: :workflow_node_result, structured_context: strat.machine.context]

    case node do
      %AgentNode{} ->
        Keyword.put(base, :tag, strat.machine.status)

      %HumanNode{} ->
        Keyword.put(base, :request_fields, %{
          agent_id: Map.get(strat, :agent_id),
          agent_module: Map.get(strat, :agent_module),
          workflow_state: strat.machine.status,
          node_name: HumanNode.name(node)
        })

      %FanOutNode{} ->
        Keyword.put(base, :fan_out_id, generate_fan_out_id())

      _ ->
        base
    end
  end

  defp apply_node_side_effects(agent, node, side_effects) do
    Enum.reduce(side_effects, agent, fn
      {:fan_out, fan_out_state}, agent ->
        StratState.update(agent, fn s -> %{s | fan_out: fan_out_state} end)

      {:pending_suspension, suspension}, agent ->
        StratState.update(agent, fn s -> %{s | pending_suspension: suspension} end)

      {:status, status}, agent ->
        StratState.update(agent, fn s -> %{s | status: status} end)

      {:children_phase, {tag, phase}}, agent ->
        StratState.update(agent, fn s ->
          %{s | children: Children.set_phase(s.children, tag, phase)}
        end)

      _, agent ->
        agent
    end)
    |> maybe_set_spawning_phase(node)
  end

  defp maybe_set_spawning_phase(agent, %AgentNode{}) do
    strat = StratState.get(agent)

    StratState.update(agent, fn s ->
      %{s | children: Children.set_phase(s.children, strat.machine.status, :spawning)}
    end)
  end

  defp maybe_set_spawning_phase(agent, _node), do: agent

  defp handle_node_suspend(agent, result, strat) do
    suspension =
      cond do
        is_map(result) and Map.has_key?(result, :__suspension__) ->
          result.__suspension__

        is_map(result) and Map.has_key?(result, :__approval_request__) ->
          request = result.__approval_request__
          {:ok, suspension} = Suspension.from_approval_request(request)
          suspension

        true ->
          {:ok, suspension} =
            Suspension.new(reason: :custom, metadata: %{node_state: strat.machine.status})

          suspension
      end

    # Merge non-suspension data into machine context
    clean_result =
      result
      |> Map.delete(:__suspension__)
      |> Map.delete(:__approval_request__)

    machine = Machine.apply_result(strat.machine, clean_result)
    agent = put_machine(agent, machine)

    agent =
      StratState.update(agent, fn s ->
        %{s | status: :waiting, pending_suspension: suspension}
      end)

    directive = %SuspendDirective{suspension: suspension}
    directives = Checkpoint.maybe_add_checkpoint_and_stop([directive], StratState.get(agent))
    {agent, directives}
  end

  defp handle_hitl_resume(agent, suspension, params) do
    response_data = params[:response_data] || params

    case ApprovalResponse.new(
           request_id: response_data[:request_id] || suspension.approval_request.id,
           decision: response_data[:decision] || response_data[:outcome],
           data: Map.get(response_data, :data),
           respondent: Map.get(response_data, :respondent),
           comment: Map.get(response_data, :comment),
           responded_at: Map.get(response_data, :responded_at, DateTime.utc_now())
         ) do
      {:ok, response} ->
        case ApprovalResponse.validate(response, suspension.approval_request) do
          :ok ->
            handle_hitl_decision(agent, response)

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

  defp handle_generic_resume(agent, params) do
    outcome = params[:outcome] || :ok
    data = params[:data] || %{}

    strat = StratState.get(agent)
    current_ctx = strat.machine.context
    merged_working = DeepMerge.deep_merge(current_ctx.working, data)
    machine = %{strat.machine | context: %{current_ctx | working: merged_working}}

    agent =
      StratState.update(agent, fn s ->
        %{s | status: :running, pending_suspension: nil}
      end)

    case Machine.transition(machine, outcome) do
      {:ok, machine} ->
        agent = put_machine(agent, machine)
        handle_after_transition(agent)

      {:error, reason} ->
        agent = put_machine(agent, machine)
        {fail_with_span(agent, reason), []}
    end
  end

  defp handle_hitl_decision(agent, %ApprovalResponse{} = response) do
    strat = StratState.get(agent)

    hitl_data = %{
      hitl_response: %{
        decision: response.decision,
        data: response.data,
        respondent: response.respondent,
        comment: response.comment,
        responded_at: response.responded_at
      }
    }

    current_ctx = strat.machine.context
    merged_working = DeepMerge.deep_merge(current_ctx.working, hitl_data)
    machine = %{strat.machine | context: %{current_ctx | working: merged_working}}

    case Machine.transition(machine, response.decision) do
      {:ok, machine} ->
        agent = put_machine(agent, machine)

        agent =
          StratState.update(agent, fn s ->
            %{s | status: :running, pending_suspension: nil}
          end)

        handle_after_transition(agent)

      {:error, reason} ->
        agent = put_machine(agent, machine)
        agent = fail_with_span(agent, reason)
        agent = StratState.update(agent, fn s -> %{s | pending_suspension: nil} end)
        {agent, []}
    end
  end

  defp build_start_context(%Context{} = current_ctx, params, strat) do
    ambient_keys = Map.get(strat, :ambient_keys, [])
    fork_fns = Map.get(strat, :fork_fns, %{})

    # If parent sent ambient data (from Context.to_flat_map), extract it
    {inherited_ambient, params} =
      case Map.pop(params, Context.ambient_key()) do
        {nil, params} -> {%{}, params}
        {ambient_map, params} -> {ambient_map, params}
      end

    if ambient_keys == [] and fork_fns == %{} and inherited_ambient == %{} do
      %{current_ctx | working: Map.merge(current_ctx.working, params)}
    else
      {ambient_vals, working_vals} = Map.split(params, ambient_keys)
      ambient = current_ctx.ambient |> Map.merge(inherited_ambient) |> Map.merge(ambient_vals)
      working = Map.merge(current_ctx.working, working_vals)

      %Context{
        ambient: ambient,
        working: working,
        fork_fns: Map.merge(current_ctx.fork_fns, fork_fns)
      }
    end
  end

  defp put_machine(agent, machine) do
    StratState.update(agent, fn strat -> %{strat | machine: machine} end)
  end

  defp put_error_reason(agent, reason) do
    StratState.update(agent, fn s -> %{s | error_reason: reason} end)
  end

  defp fail_with_span(agent, error_reason) do
    agent = put_error_reason(agent, error_reason)
    agent = StratState.set_status(agent, :failure)
    agent = finish_agent_span(agent, %{error: error_reason})
    agent
  end

  # -- FanOut helpers --

  defp handle_fan_out_branch_result(agent, fan_out, branch_name, result, _strat) do
    case result do
      {:ok, branch_result} ->
        fan_out = FanOutState.branch_completed(fan_out, branch_name, branch_result)
        {fan_out, new_directives} = dispatch_queued_branches(fan_out)
        agent = StratState.update(agent, fn s -> %{s | fan_out: fan_out} end)
        maybe_complete_fan_out(agent, new_directives)

      {:suspend, %Suspension{} = suspension} ->
        handle_fan_out_branch_suspend(agent, fan_out, branch_name, suspension, nil, nil)

      {:suspend, %Suspension{} = suspension, partial_result} ->
        handle_fan_out_branch_suspend(
          agent,
          fan_out,
          branch_name,
          suspension,
          partial_result,
          nil
        )

      {:error, reason} ->
        case fan_out.on_error do
          :fail_fast ->
            cancel_and_fail(agent, fan_out, reason)

          :collect_partial ->
            fan_out = FanOutState.branch_error(fan_out, branch_name, reason)
            {fan_out, new_directives} = dispatch_queued_branches(fan_out)
            agent = StratState.update(agent, fn s -> %{s | fan_out: fan_out} end)
            maybe_complete_fan_out(agent, new_directives)
        end
    end
  end

  defp handle_fan_out_branch_suspend(
         agent,
         fan_out,
         branch_name,
         suspension,
         partial_result,
         _strat
       ) do
    fan_out = FanOutState.branch_suspended(fan_out, branch_name, suspension, partial_result)
    {fan_out, new_directives} = dispatch_queued_branches(fan_out)

    agent = StratState.update(agent, fn s -> %{s | fan_out: fan_out} end)
    maybe_complete_fan_out(agent, new_directives)
  end

  defp dispatch_queued_branches(fan_out) do
    {fan_out, to_dispatch} = FanOutState.drain_queue(fan_out)
    directives = Enum.map(to_dispatch, fn {_name, directive} -> directive end)
    {fan_out, directives}
  end

  defp maybe_complete_fan_out(agent, extra_directives) do
    strat = StratState.get(agent)
    fan_out = strat.fan_out

    case FanOutState.completion_status(fan_out) do
      :all_done ->
        merged = FanOutState.merge_results(fan_out)
        machine = Machine.apply_result(strat.machine, merged)

        agent = StratState.update(agent, fn s -> %{s | fan_out: nil} end)

        case Machine.transition(machine, :ok) do
          {:ok, machine} ->
            agent = put_machine(agent, machine)
            handle_after_transition(agent)

          {:error, reason} ->
            agent = put_machine(agent, machine)
            {fail_with_span(agent, reason), []}
        end

      :suspended ->
        suspend_directives =
          Enum.map(fan_out.suspended_branches, fn {_branch_name, %{suspension: sus}} ->
            %SuspendDirective{suspension: sus}
          end)

        agent = StratState.update(agent, fn s -> %{s | status: :waiting} end)
        all_directives = extra_directives ++ suspend_directives

        all_directives =
          Checkpoint.maybe_add_checkpoint_and_stop(all_directives, StratState.get(agent))

        {agent, all_directives}

      :in_progress ->
        {agent, extra_directives}
    end
  end

  defp has_suspended_fan_out_branch?(strat, suspension_id) do
    case strat.fan_out do
      %FanOutState{} = fan_out -> FanOutState.has_suspended_branch?(fan_out, suspension_id)
      _ -> false
    end
  end

  defp find_suspended_fan_out_branch(fan_out, suspension_id) do
    FanOutState.find_suspended_branch(fan_out, suspension_id)
  end

  defp handle_fan_out_branch_resume(agent, strat, suspension_id, params) do
    fan_out = strat.fan_out
    {branch_name, _branch_data} = find_suspended_fan_out_branch(fan_out, suspension_id)
    outcome = params[:outcome] || :ok
    data = params[:data] || %{}

    result =
      if outcome == :ok,
        do: {:ok, data},
        else: {:error, params[:error] || :suspension_failed}

    complete_suspended_fan_out_branch(agent, fan_out, branch_name, result)
  end

  defp complete_suspended_fan_out_branch(agent, fan_out, branch_name, result) do
    fan_out = FanOutState.resume_branch(fan_out, branch_name)

    agent =
      StratState.update(agent, fn s -> %{s | fan_out: fan_out, status: :running} end)

    strat = StratState.get(agent)
    handle_fan_out_branch_result(agent, strat.fan_out, branch_name, result, strat)
  end

  defp handle_fan_out_branch_timeout(agent, strat, suspension_id) do
    fan_out = strat.fan_out
    {branch_name, _} = find_suspended_fan_out_branch(fan_out, suspension_id)
    complete_suspended_fan_out_branch(agent, fan_out, branch_name, {:error, :suspension_timeout})
  end

  defp cancel_and_fail(agent, fan_out, reason) do
    stop_directives =
      fan_out.pending_branches
      |> MapSet.to_list()
      |> Enum.map(fn branch_name ->
        Directive.stop_child({:fan_out, fan_out.id, branch_name})
      end)

    agent = put_error_reason(agent, reason)
    agent = StratState.update(agent, fn s -> %{s | fan_out: nil} end)
    strat = StratState.get(agent)

    case Machine.transition(strat.machine, :error) do
      {:ok, machine} ->
        agent = put_machine(agent, machine)
        handle_after_transition_with_directives(agent, stop_directives)

      {:error, _transition_reason} ->
        agent = StratState.set_status(agent, :failure)
        agent = finish_agent_span(agent, %{error: reason})
        {agent, stop_directives}
    end
  end

  defp handle_after_transition_with_directives(agent, extra_directives) do
    strat = StratState.get(agent)

    if Machine.terminal?(strat.machine) do
      success_states = Map.get(strat, :success_states, [:done])
      status = if strat.machine.status in success_states, do: :success, else: :failure
      agent = StratState.set_status(agent, status)

      # When no explicit error_reason was captured, use the terminal state atom
      agent =
        if status == :failure and is_nil(Map.get(strat, :error_reason)) do
          StratState.update(agent, fn s -> Map.put(s, :error_reason, strat.machine.status) end)
        else
          agent
        end

      strat = StratState.get(agent)

      extra =
        if status == :failure do
          case Map.get(strat, :error_reason) do
            nil -> %{}
            er -> %{error: er}
          end
        else
          %{}
        end

      agent = finish_agent_span(agent, extra)
      {agent, extra_directives}
    else
      {agent, node_directives} = dispatch_current_node(agent)
      {agent, extra_directives ++ node_directives}
    end
  end

  defp generate_fan_out_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  # -- Checkpoint hooks --

  @doc false
  def prepare_for_checkpoint(agent) do
    strat = StratState.get(agent)
    cleaned = Checkpoint.prepare_for_checkpoint(strat)
    StratState.put(agent, cleaned)
  end

  @doc """
  Strategy-specific closure stripping for checkpoint serialization.

  Called by `Checkpoint.prepare_for_checkpoint/1` via delegation.
  Workflows have no nested closures, so this just strips top-level functions.
  """
  @spec strip_for_checkpoint(map()) :: map()
  def strip_for_checkpoint(state) do
    Map.new(state, fn
      {:_obs, _} -> {:_obs, Obs.new()}
      {k, v} when is_function(v) -> {k, nil}
      kv -> kv
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

  defp finish_agent_span(agent, extra) do
    state = StratState.get(agent)
    obs = Obs.finish_agent_span(state._obs, state, extra)
    StratState.update(agent, fn s -> %{s | _obs: obs} end)
  end

  defp maybe_reattach_parent_otel_ctx(agent) do
    case agent do
      %{state: %{__parent__: %{meta: %{otel_parent_ctx: otel_ctx}}}} when otel_ctx != nil ->
        Logger.debug("obs: reattaching parent OTel context for workflow agent")
        OtelCtx.attach(otel_ctx)

      _ ->
        Logger.debug("obs: no parent OTel context found for workflow agent")
        :ok
    end
  end

  defp build_nodes(node_specs) when is_map(node_specs) do
    Map.new(node_specs, fn
      {state_name, {:action, action_module}} ->
        {:ok, node} = ActionNode.new(action_module)
        {state_name, node}

      {state_name, {:agent, agent_module, opts}} ->
        {:ok, node} = AgentNode.new(agent_module, opts)
        {state_name, node}

      {state_name, %ActionNode{} = node} ->
        {state_name, node}

      {state_name, %AgentNode{} = node} ->
        {state_name, node}

      {state_name, node} when is_struct(node) ->
        {state_name, node}
    end)
  end
end
