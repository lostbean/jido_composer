defmodule Jido.Composer.Workflow.Strategy do
  @moduledoc """
  Jido.Agent.Strategy implementation for deterministic FSM-based workflows.

  Drives a `Jido.Composer.Workflow.Machine` through its states by emitting
  directives. Keeps `cmd/3` pure — no side effects.
  """

  use Jido.Agent.Strategy

  alias Jido.Agent.Directive
  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.Composer.Context
  alias Jido.Composer.Directive.SuspendForHuman
  alias Jido.Composer.HITL.{ApprovalRequest, ApprovalResponse}
  alias Jido.Composer.Node.ActionNode
  alias Jido.Composer.Node.AgentNode
  alias Jido.Composer.Node.FanOutNode
  alias Jido.Composer.Node.HumanNode
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
        pending_approval: nil,
        ambient_keys: opts[:ambient] || [],
        fork_fns: opts[:fork_fns] || %{}
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

  def cmd(agent, [%Jido.Instruction{action: :workflow_child_started} | _rest], _ctx) do
    # Child agent has started — no action needed for sync mode.
    # The SpawnAgent directive already contains the context; the AgentServer
    # handles delivery to the child.
    {agent, []}
  end

  def cmd(agent, [%Jido.Instruction{action: :workflow_child_result} = instr | _rest], _ctx) do
    strat = StratState.get(agent)
    params = instr.params

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

  def cmd(agent, [%Jido.Instruction{action: :workflow_child_exit} | _rest], _ctx) do
    # Child agent has exited — cleanup if needed
    {agent, []}
  end

  def cmd(agent, [%Jido.Instruction{action: :hitl_response} = instr | _rest], _ctx) do
    strat = StratState.get(agent)

    case strat.pending_approval do
      nil ->
        {agent, [%Directive.Error{error: %RuntimeError{message: "No pending HITL request"}}]}

      %ApprovalRequest{} = request ->
        response_data = instr.params

        {:ok, response} =
          ApprovalResponse.new(
            request_id: response_data.request_id,
            decision: response_data.decision,
            data: Map.get(response_data, :data),
            respondent: Map.get(response_data, :respondent),
            comment: Map.get(response_data, :comment),
            responded_at: Map.get(response_data, :responded_at, DateTime.utc_now())
          )

        case ApprovalResponse.validate(response, request) do
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
    end
  end

  def cmd(agent, [%Jido.Instruction{action: :hitl_timeout} = instr | _rest], _ctx) do
    strat = StratState.get(agent)
    request_id = instr.params[:request_id]

    case strat.pending_approval do
      %ApprovalRequest{id: ^request_id} = request ->
        timeout_outcome = request.timeout_outcome

        agent =
          StratState.update(agent, fn s -> %{s | status: :running, pending_approval: nil} end)

        strat = StratState.get(agent)
        machine = strat.machine

        case Machine.transition(machine, timeout_outcome) do
          {:ok, machine} ->
            agent = put_machine(agent, machine)
            handle_after_transition(agent)

          {:error, _reason} ->
            agent = StratState.set_status(agent, :failure)
            {agent, []}
        end

      _ ->
        # Already resolved or mismatched — ignore
        {agent, []}
    end
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
      {"composer.hitl.response", {:strategy_cmd, :hitl_response}},
      {"composer.hitl.timeout", {:strategy_cmd, :hitl_timeout}}
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
      case Map.get(strat, :pending_approval) do
        %ApprovalRequest{} = request ->
          Map.merge(details, %{
            reason: :awaiting_approval,
            request_id: request.id,
            node_name: request.node_name
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
        child_context = Context.fork_for_child(strat.machine.context)
        child_flat = Context.to_flat_map(child_context)

        directive = %Directive.SpawnAgent{
          tag: strat.machine.status,
          agent: agent_module,
          opts: Map.new(opts) |> Map.put(:context, child_flat)
        }

        {agent, [directive]}

      %HumanNode{} = human_node ->
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

        # Store pending approval, set status to :waiting
        agent =
          StratState.update(agent, fn s ->
            %{s | status: :waiting, pending_approval: request}
          end)

        {:ok, directive} = SuspendForHuman.new(approval_request: request)
        {agent, [directive]}

      %FanOutNode{} = fan_out_node ->
        # FanOutNode encapsulates concurrency internally — execute and process result
        case FanOutNode.run(fan_out_node, Context.to_flat_map(strat.machine.context)) do
          {:ok, result} ->
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

          {:error, _reason} ->
            case Machine.transition(strat.machine, :error) do
              {:ok, machine} ->
                agent = put_machine(agent, machine)
                handle_after_transition(agent)

              {:error, _reason} ->
                agent = StratState.set_status(agent, :failure)
                {agent, []}
            end
        end

      nil ->
        {agent, []}
    end
  end

  defp handle_hitl_decision(agent, %ApprovalResponse{} = response) do
    # Merge response data into machine context working layer
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

    # Use decision as transition outcome
    case Machine.transition(machine, response.decision) do
      {:ok, machine} ->
        agent = put_machine(agent, machine)

        agent =
          StratState.update(agent, fn s ->
            %{s | status: :running, pending_approval: nil}
          end)

        handle_after_transition(agent)

      {:error, _reason} ->
        agent = put_machine(agent, machine)
        agent = StratState.set_status(agent, :failure)

        agent =
          StratState.update(agent, fn s -> %{s | pending_approval: nil} end)

        {agent, []}
    end
  end

  defp build_start_context(%Context{} = current_ctx, params, strat) do
    ambient_keys = Map.get(strat, :ambient_keys, [])
    fork_fns = Map.get(strat, :fork_fns, %{})

    if ambient_keys == [] and fork_fns == %{} do
      # No ambient/fork config — just merge params into working
      %{current_ctx | working: Map.merge(current_ctx.working, params)}
    else
      # Extract ambient keys from params
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

  defp build_nodes(node_specs) when is_map(node_specs) do
    Map.new(node_specs, fn
      {state_name, {:action, action_module}} ->
        {:ok, node} = ActionNode.new(action_module)
        {state_name, node}

      {state_name, {:agent, agent_module, opts}} ->
        {:ok, node} = AgentNode.new(agent_module, opts: opts)
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
