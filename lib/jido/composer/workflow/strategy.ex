defmodule Jido.Composer.Workflow.Strategy do
  @moduledoc """
  Jido.Agent.Strategy implementation for deterministic FSM-based workflows.

  Drives a `Jido.Composer.Workflow.Machine` through its states by emitting
  directives. Keeps `cmd/3` pure — no side effects.
  """

  use Jido.Agent.Strategy

  alias Jido.Agent.Directive
  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.Composer.Checkpoint
  alias Jido.Composer.ChildRef
  alias Jido.Composer.Context
  alias Jido.Composer.Directive.FanOutBranch
  alias Jido.Composer.Directive.Suspend, as: SuspendDirective
  alias Jido.Composer.Directive.SuspendForHuman
  alias Jido.Composer.HITL.{ApprovalRequest, ApprovalResponse}
  alias Jido.Composer.Node.ActionNode
  alias Jido.Composer.Node.AgentNode
  alias Jido.Composer.Node.FanOutNode
  alias Jido.Composer.Node.HumanNode
  alias Jido.Composer.Suspension
  alias Jido.Composer.Workflow.Machine

  # -- init/2 --

  @impl true
  def init(agent, ctx) do
    opts = ctx.strategy_opts
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
        machine: machine,
        pending_child: nil,
        child_request_id: nil,
        pending_suspension: nil,
        pending_fan_out: nil,
        ambient_keys: opts[:ambient] || [],
        fork_fns: opts[:fork_fns] || %{},
        children: %{},
        child_phases: %{},
        agent_id: agent.id,
        agent_module: ctx[:agent_module]
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

    dispatch_current_node(agent)
  end

  def cmd(agent, [%Jido.Instruction{action: :workflow_node_result} = instr | _rest], _ctx) do
    strat = StratState.get(agent)
    params = instr.params

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

          {:error, _reason} ->
            agent = put_machine(agent, machine)
            agent = StratState.set_status(agent, :failure)
            {agent, []}
        end

      %{status: :error} ->
        machine = strat.machine

        case Machine.transition(machine, :error) do
          {:ok, machine} ->
            agent = put_machine(agent, machine)
            handle_after_transition(agent)

          {:error, _reason} ->
            agent = StratState.set_status(agent, :failure)
            {agent, []}
        end
    end
  end

  def cmd(agent, [%Jido.Instruction{action: :workflow_child_started} = instr | _rest], _ctx) do
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
        %{
          s
          | children: Map.put(s.children, tag, child_ref),
            child_phases: Map.put(Map.get(s, :child_phases, %{}), tag, :awaiting_result)
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
        %{s | child_phases: Map.delete(Map.get(s, :child_phases, %{}), tag)}
      end)

    case params do
      %{result: {:ok, result}} ->
        machine = Machine.apply_result(strat.machine, result)

        case Machine.transition(machine, :ok) do
          {:ok, machine} ->
            agent = put_machine(agent, machine)
            handle_after_transition(agent)

          {:error, _reason} ->
            agent = put_machine(agent, machine)
            agent = StratState.set_status(agent, :failure)
            {agent, []}
        end

      %{result: {:error, _reason}} ->
        case Machine.transition(strat.machine, :error) do
          {:ok, machine} ->
            agent = put_machine(agent, machine)
            handle_after_transition(agent)

          {:error, _reason} ->
            agent = StratState.set_status(agent, :failure)
            {agent, []}
        end
    end
  end

  def cmd(agent, [%Jido.Instruction{action: :workflow_child_exit} = instr | _rest], _ctx) do
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

  def cmd(agent, [%Jido.Instruction{action: :fan_out_branch_result} = instr | _rest], _ctx) do
    strat = StratState.get(agent)
    params = instr.params
    branch_name = params[:branch_name]
    result = params[:result]
    fan_out = strat.pending_fan_out

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

          {:error, _reason} ->
            agent = StratState.set_status(agent, :failure)
            {agent, []}
        end

      has_suspended_fan_out_branch?(strat, suspension_id) ->
        handle_fan_out_branch_timeout(agent, strat, suspension_id)

      true ->
        {agent, []}
    end
  end

  # Legacy HITL response — delegate to suspend_resume
  def cmd(agent, [%Jido.Instruction{action: :hitl_response} = instr | _rest], _ctx) do
    strat = StratState.get(agent)

    case strat.pending_suspension do
      nil ->
        {agent, [%Directive.Error{error: %RuntimeError{message: "No pending HITL request"}}]}

      %Suspension{reason: :human_input} = suspension ->
        response_data = instr.params

        case ApprovalResponse.new(
               request_id: response_data.request_id,
               decision: response_data.decision,
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

      %Suspension{} ->
        {agent,
         [%Directive.Error{error: %RuntimeError{message: "Pending suspension is not HITL"}}]}
    end
  end

  # Legacy HITL timeout — delegate to suspend_timeout
  def cmd(agent, [%Jido.Instruction{action: :hitl_timeout} = instr | _rest], _ctx) do
    strat = StratState.get(agent)
    request_id = instr.params[:request_id]

    case strat.pending_suspension do
      %Suspension{reason: :human_input, approval_request: %ApprovalRequest{id: ^request_id}} =
          suspension ->
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

          {:error, _reason} ->
            agent = StratState.set_status(agent, :failure)
            {agent, []}
        end

      _ ->
        {agent, []}
    end
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
      {"composer.workflow.start", {:strategy_cmd, :workflow_start}},
      {"composer.workflow.child.result", {:strategy_cmd, :workflow_child_result}},
      {"jido.agent.child.started", {:strategy_cmd, :workflow_child_started}},
      {"jido.agent.child.exit", {:strategy_cmd, :workflow_child_exit}},
      {"composer.fan_out.branch_result", {:strategy_cmd, :fan_out_branch_result}},
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
      case Map.get(strat, :pending_fan_out) do
        %{suspended_branches: branches} when is_map(branches) and branches != %{} ->
          completed_count =
            case Map.get(strat, :pending_fan_out) do
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
        %Context{} -> Context.to_flat_map(raw_context)
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
      status = if strat.machine.status == :done, do: :success, else: :failure
      agent = StratState.set_status(agent, status)
      {agent, []}
    else
      dispatch_current_node(agent)
    end
  end

  defp dispatch_current_node(agent) do
    strat = StratState.get(agent)
    node = Machine.current_node(strat.machine)

    case node do
      %ActionNode{action_module: action_module} ->
        instruction = %Jido.Instruction{
          action: action_module,
          params: Context.to_flat_map(strat.machine.context)
        }

        directive = %Directive.RunInstruction{
          instruction: instruction,
          result_action: :workflow_node_result
        }

        {agent, [directive]}

      %AgentNode{agent_module: agent_module, opts: opts} ->
        tag = strat.machine.status
        child_context = Context.fork_for_child(strat.machine.context)
        child_flat = Context.to_flat_map(child_context)

        agent =
          StratState.update(agent, fn s ->
            %{s | child_phases: Map.put(s.child_phases, tag, :spawning)}
          end)

        directive = %Directive.SpawnAgent{
          tag: tag,
          agent: agent_module,
          opts: Map.new(opts) |> Map.put(:context, child_flat)
        }

        {agent, [directive]}

      %HumanNode{} = human_node ->
        dispatch_human_node(agent, human_node, strat)

      %FanOutNode{} = fan_out_node ->
        dispatch_fan_out(agent, fan_out_node, strat)

      nil ->
        {agent, []}
    end
  end

  defp dispatch_human_node(agent, human_node, strat) do
    flat_context = Context.to_flat_map(strat.machine.context)
    {:ok, updated_context, :suspend} = HumanNode.run(human_node, flat_context)

    # Extract and enrich the ApprovalRequest
    request = updated_context.__approval_request__

    request = %{
      request
      | agent_id: Map.get(strat, :agent_id),
        agent_module: Map.get(strat, :agent_module),
        workflow_state: strat.machine.status,
        node_name: HumanNode.name(human_node)
    }

    # Create Suspension from ApprovalRequest
    {:ok, suspension} = Suspension.from_approval_request(request)

    # Store pending suspension, set status to :waiting
    agent =
      StratState.update(agent, fn s ->
        %{s | status: :waiting, pending_suspension: suspension}
      end)

    case SuspendForHuman.new(approval_request: request) do
      {:ok, directive} ->
        {agent, [directive]}

      {:error, reason} ->
        {agent,
         [
           %Directive.Error{
             error: %RuntimeError{message: "Failed to create HITL directive: #{reason}"}
           }
         ]}
    end
  end

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
    {agent, [directive]}
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

      {:error, _reason} ->
        agent = put_machine(agent, machine)
        agent = StratState.set_status(agent, :failure)
        {agent, []}
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

      {:error, _reason} ->
        agent = put_machine(agent, machine)
        agent = StratState.set_status(agent, :failure)

        agent =
          StratState.update(agent, fn s -> %{s | pending_suspension: nil} end)

        {agent, []}
    end
  end

  defp build_start_context(%Context{} = current_ctx, params, strat) do
    ambient_keys = Map.get(strat, :ambient_keys, [])
    fork_fns = Map.get(strat, :fork_fns, %{})

    if ambient_keys == [] and fork_fns == %{} do
      %{current_ctx | working: Map.merge(current_ctx.working, params)}
    else
      {ambient_vals, working_vals} = Map.split(params, ambient_keys)
      ambient = Map.merge(current_ctx.ambient, ambient_vals)
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

  # -- FanOut helpers --

  defp handle_fan_out_branch_result(agent, fan_out, branch_name, result, strat) do
    case result do
      {:ok, branch_result} ->
        completed = Map.put(fan_out.completed_results, branch_name, branch_result)

        pending =
          fan_out.pending_branches
          |> MapSet.delete(branch_name)

        fan_out = %{fan_out | completed_results: completed, pending_branches: pending}

        {fan_out, new_directives} = dispatch_queued_branches(fan_out, strat)

        agent =
          StratState.update(agent, fn s -> %{s | pending_fan_out: fan_out} end)

        maybe_complete_fan_out(agent, new_directives)

      {:suspend, %Suspension{} = suspension} ->
        handle_fan_out_branch_suspend(agent, fan_out, branch_name, suspension, nil, strat)

      {:suspend, %Suspension{} = suspension, partial_result} ->
        handle_fan_out_branch_suspend(
          agent,
          fan_out,
          branch_name,
          suspension,
          partial_result,
          strat
        )

      {:error, reason} ->
        case fan_out.on_error do
          :fail_fast ->
            cancel_and_fail(agent, fan_out, reason)

          :collect_partial ->
            completed = Map.put(fan_out.completed_results, branch_name, {:error, reason})

            pending =
              fan_out.pending_branches
              |> MapSet.delete(branch_name)

            fan_out = %{fan_out | completed_results: completed, pending_branches: pending}

            {fan_out, new_directives} = dispatch_queued_branches(fan_out, strat)

            agent =
              StratState.update(agent, fn s -> %{s | pending_fan_out: fan_out} end)

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
         strat
       ) do
    pending = MapSet.delete(fan_out.pending_branches, branch_name)

    suspended =
      Map.put(fan_out.suspended_branches, branch_name, %{
        suspension: suspension,
        partial_result: partial_result
      })

    fan_out = %{fan_out | pending_branches: pending, suspended_branches: suspended}
    {fan_out, new_directives} = dispatch_queued_branches(fan_out, strat)

    agent = StratState.update(agent, fn s -> %{s | pending_fan_out: fan_out} end)
    maybe_complete_fan_out(agent, new_directives)
  end

  defp dispatch_fan_out(agent, %FanOutNode{} = fan_out_node, strat) do
    fan_out_id = generate_fan_out_id()
    flat_context = Context.to_flat_map(strat.machine.context)

    all_branches =
      Enum.map(fan_out_node.branches, fn {branch_name, branch_node} ->
        {branch_name,
         build_fan_out_directive(fan_out_id, branch_name, branch_node, flat_context, strat)}
      end)

    max_concurrency = fan_out_node.max_concurrency || length(all_branches)
    {to_dispatch, to_queue} = Enum.split(all_branches, max_concurrency)

    dispatched_names = Enum.map(to_dispatch, fn {name, _} -> name end) |> MapSet.new()

    fan_out_state = %{
      id: fan_out_id,
      node: fan_out_node,
      pending_branches: dispatched_names,
      completed_results: %{},
      suspended_branches: %{},
      queued_branches: to_queue,
      merge: fan_out_node.merge,
      on_error: fan_out_node.on_error
    }

    agent =
      StratState.update(agent, fn s -> %{s | pending_fan_out: fan_out_state} end)

    directives = Enum.map(to_dispatch, fn {_name, directive} -> directive end)
    {agent, directives}
  end

  defp build_fan_out_directive(fan_out_id, branch_name, branch_node, flat_context, strat) do
    case branch_node do
      %ActionNode{action_module: action_module} ->
        %FanOutBranch{
          fan_out_id: fan_out_id,
          branch_name: branch_name,
          instruction: %Jido.Instruction{
            action: action_module,
            params: flat_context
          },
          result_action: :fan_out_branch_result
        }

      %AgentNode{agent_module: agent_module, opts: opts} ->
        child_context = Context.fork_for_child(strat.machine.context)
        child_flat = Context.to_flat_map(child_context)

        %FanOutBranch{
          fan_out_id: fan_out_id,
          branch_name: branch_name,
          spawn_agent: %{
            agent: agent_module,
            opts: Map.new(opts) |> Map.put(:context, child_flat)
          },
          result_action: :fan_out_branch_result
        }

      fun when is_function(fun, 1) ->
        %FanOutBranch{
          fan_out_id: fan_out_id,
          branch_name: branch_name,
          instruction: {:function, fun, flat_context},
          result_action: :fan_out_branch_result
        }
    end
  end

  defp dispatch_queued_branches(fan_out, _strat) when fan_out.queued_branches == [],
    do: {fan_out, []}

  defp dispatch_queued_branches(fan_out, _strat) do
    max =
      (fan_out.node.max_concurrency || length(fan_out.node.branches)) -
        MapSet.size(fan_out.pending_branches)

    if max <= 0 do
      {fan_out, []}
    else
      {to_dispatch, remaining} = Enum.split(fan_out.queued_branches, max)
      new_pending_names = Enum.map(to_dispatch, fn {name, _} -> name end)
      pending = Enum.reduce(new_pending_names, fan_out.pending_branches, &MapSet.put(&2, &1))
      directives = Enum.map(to_dispatch, fn {_name, directive} -> directive end)
      fan_out = %{fan_out | pending_branches: pending, queued_branches: remaining}
      {fan_out, directives}
    end
  end

  defp maybe_complete_fan_out(agent, extra_directives) do
    strat = StratState.get(agent)
    fan_out = strat.pending_fan_out

    cond do
      # All done, no suspensions -> merge & transition
      MapSet.size(fan_out.pending_branches) == 0 and
        fan_out.queued_branches == [] and
          fan_out.suspended_branches == %{} ->
        merged = FanOutNode.merge_results(fan_out.completed_results, fan_out.merge)
        machine = Machine.apply_result(strat.machine, merged)

        agent = StratState.update(agent, fn s -> %{s | pending_fan_out: nil} end)

        case Machine.transition(machine, :ok) do
          {:ok, machine} ->
            agent = put_machine(agent, machine)
            handle_after_transition(agent)

          {:error, _reason} ->
            agent = put_machine(agent, machine)
            agent = StratState.set_status(agent, :failure)
            {agent, []}
        end

      # All running done, suspensions remain -> emit Suspend directives
      MapSet.size(fan_out.pending_branches) == 0 and
        fan_out.queued_branches == [] and
          fan_out.suspended_branches != %{} ->
        suspend_directives =
          Enum.map(fan_out.suspended_branches, fn {_branch_name, %{suspension: sus}} ->
            %SuspendDirective{suspension: sus}
          end)

        agent = StratState.update(agent, fn s -> %{s | status: :waiting} end)
        {agent, extra_directives ++ suspend_directives}

      # Still running -> pass through
      true ->
        {agent, extra_directives}
    end
  end

  defp has_suspended_fan_out_branch?(strat, suspension_id) do
    case strat.pending_fan_out do
      %{suspended_branches: branches} when is_map(branches) and branches != %{} ->
        Enum.any?(branches, fn {_name, %{suspension: %Suspension{id: id}}} ->
          id == suspension_id
        end)

      _ ->
        false
    end
  end

  defp find_suspended_fan_out_branch(fan_out, suspension_id) do
    Enum.find(fan_out.suspended_branches, fn {_name, %{suspension: %Suspension{id: id}}} ->
      id == suspension_id
    end)
  end

  defp handle_fan_out_branch_resume(agent, strat, suspension_id, params) do
    fan_out = strat.pending_fan_out
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
    fan_out = %{
      fan_out
      | suspended_branches: Map.delete(fan_out.suspended_branches, branch_name)
    }

    agent =
      StratState.update(agent, fn s -> %{s | pending_fan_out: fan_out, status: :running} end)

    strat = StratState.get(agent)
    handle_fan_out_branch_result(agent, strat.pending_fan_out, branch_name, result, strat)
  end

  defp handle_fan_out_branch_timeout(agent, strat, suspension_id) do
    fan_out = strat.pending_fan_out
    {branch_name, _} = find_suspended_fan_out_branch(fan_out, suspension_id)
    complete_suspended_fan_out_branch(agent, fan_out, branch_name, {:error, :suspension_timeout})
  end

  defp cancel_and_fail(agent, fan_out, _reason) do
    stop_directives =
      fan_out.pending_branches
      |> MapSet.to_list()
      |> Enum.map(fn branch_name ->
        Directive.stop_child({:fan_out, fan_out.id, branch_name})
      end)

    agent = StratState.update(agent, fn s -> %{s | pending_fan_out: nil} end)
    strat = StratState.get(agent)

    case Machine.transition(strat.machine, :error) do
      {:ok, machine} ->
        agent = put_machine(agent, machine)
        handle_after_transition_with_directives(agent, stop_directives)

      {:error, _reason} ->
        agent = StratState.set_status(agent, :failure)
        {agent, stop_directives}
    end
  end

  defp handle_after_transition_with_directives(agent, extra_directives) do
    strat = StratState.get(agent)

    if Machine.terminal?(strat.machine) do
      status = if strat.machine.status == :done, do: :success, else: :failure
      agent = StratState.set_status(agent, status)
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

  @doc false
  def reattach_runtime_config(agent, strategy_opts) do
    strat = StratState.get(agent)
    restored = Checkpoint.reattach_runtime_config(strat, strategy_opts)
    StratState.put(agent, restored)
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
