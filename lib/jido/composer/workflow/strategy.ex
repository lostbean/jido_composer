defmodule Jido.Composer.Workflow.Strategy do
  @moduledoc """
  Jido.Agent.Strategy implementation for deterministic FSM-based workflows.

  Drives a `Jido.Composer.Workflow.Machine` through its states by emitting
  directives. Keeps `cmd/3` pure — no side effects.
  """

  use Jido.Agent.Strategy

  alias Jido.Agent.Directive
  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.Composer.Node.ActionNode
  alias Jido.Composer.Node.AgentNode
  alias Jido.Composer.Node.FanOutNode
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
        child_request_id: nil
      })

    {agent, []}
  end

  # -- cmd/3 --

  @impl true
  def cmd(agent, [%Jido.Instruction{action: :workflow_start} = instr | _rest], _ctx) do
    agent = StratState.set_status(agent, :running)
    strat = StratState.get(agent)

    # Merge initial params into machine context
    machine = %{strat.machine | context: Map.merge(strat.machine.context, instr.params || %{})}
    agent = put_machine(agent, machine)

    dispatch_current_node(agent)
  end

  def cmd(agent, [%Jido.Instruction{action: :workflow_node_result} = instr | _rest], _ctx) do
    strat = StratState.get(agent)
    params = instr.params

    case params do
      %{status: :ok, result: result} ->
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
      {"jido.agent.child.exit", {:strategy_cmd, :workflow_child_exit}}
    ]
  end

  # -- snapshot/2 --

  @impl true
  def snapshot(agent, _ctx) do
    strat = StratState.get(agent, %{})
    status = Map.get(strat, :status, :idle)

    %Jido.Agent.Strategy.Snapshot{
      status: status,
      done?: status in [:success, :failure],
      result: get_in(strat, [:machine, Access.key(:context)]),
      details: %{
        state: get_in(strat, [:machine, Access.key(:status)])
      }
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
          params: strat.machine.context
        }

        directive = %Directive.RunInstruction{
          instruction: instruction,
          result_action: :workflow_node_result
        }

        {agent, [directive]}

      %AgentNode{agent_module: agent_module, opts: opts} ->
        directive = %Directive.SpawnAgent{
          tag: strat.machine.status,
          agent: agent_module,
          opts: Map.new(opts)
        }

        {agent, [directive]}

      %FanOutNode{} = fan_out_node ->
        # FanOutNode encapsulates concurrency internally — execute and process result
        case FanOutNode.run(fan_out_node, strat.machine.context) do
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
