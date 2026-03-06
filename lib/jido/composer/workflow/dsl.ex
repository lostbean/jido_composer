defmodule Jido.Composer.Workflow.DSL do
  @moduledoc """
  Compile-time macro for declarative workflow agent definitions.

  `use Jido.Composer.Workflow` generates a `Jido.Agent` module wired
  to the `Jido.Composer.Workflow.Strategy` with validated configuration.

  ## Example

      defmodule MyETLPipeline do
        use Jido.Composer.Workflow,
          name: "etl_pipeline",
          nodes: %{
            extract:   ExtractAction,
            transform: TransformAction,
            load:      LoadAction
          },
          transitions: %{
            {:extract, :ok}   => :transform,
            {:transform, :ok} => :load,
            {:load, :ok}      => :done,
            {:_, :error}      => :failed
          },
          initial: :extract
      end
  """

  defmacro __using__(opts) do
    name = Keyword.fetch!(opts, :name)
    description = Keyword.get(opts, :description, "Workflow: #{name}")
    schema = Keyword.get(opts, :schema, [])
    initial = Keyword.fetch!(opts, :initial)
    terminal_states = Keyword.get(opts, :terminal_states)

    # Generate signal routes from strategy (computed at compile time — these are static)
    workflow_routes = Jido.Composer.Workflow.Strategy.signal_routes(%{})

    # nodes and transitions are passed through as AST and evaluated at compile time
    # inside the generated module via module attributes
    nodes_ast = Keyword.fetch!(opts, :nodes)
    transitions_ast = Keyword.fetch!(opts, :transitions)

    quote do
      # Evaluate nodes and transitions at module compile time
      @__wf_nodes_raw__ unquote(nodes_ast)
      @__wf_transitions__ unquote(transitions_ast)
      @__wf_initial__ unquote(initial)
      @__wf_terminal_states__ unquote(Macro.escape(terminal_states))

      # Wrap bare action modules: MyAction -> {:action, MyAction}
      @__wf_nodes__ Jido.Composer.Workflow.DSL.__wrap_nodes__(@__wf_nodes_raw__)

      # Validate configuration
      Jido.Composer.Workflow.DSL.__validate__!(
        @__wf_nodes_raw__,
        @__wf_transitions__,
        @__wf_initial__,
        @__wf_terminal_states__
      )

      # Build strategy opts
      @__wf_strategy_opts__ [
                              nodes: @__wf_nodes__,
                              transitions: @__wf_transitions__,
                              initial: @__wf_initial__
                            ] ++
                              if(@__wf_terminal_states__,
                                do: [terminal_states: @__wf_terminal_states__],
                                else: []
                              )

      use Jido.Agent,
        name: unquote(name),
        description: unquote(description),
        schema: unquote(Macro.escape(schema)),
        strategy: {Jido.Composer.Workflow.Strategy, @__wf_strategy_opts__},
        signal_routes: unquote(Macro.escape(workflow_routes))

      @doc "Starts the workflow with the given context."
      @spec run(Jido.Agent.t(), map()) :: Jido.Agent.cmd_result()
      def run(%Jido.Agent{} = agent, context \\ %{}) when is_map(context) do
        __MODULE__.cmd(agent, {:workflow_start, context})
      end

      @doc "Runs the workflow synchronously, blocking until terminal state."
      @spec run_sync(Jido.Agent.t(), map()) :: {:ok, map()} | {:error, term()}
      def run_sync(%Jido.Agent{} = agent, context \\ %{}) when is_map(context) do
        {agent, directives} = run(agent, context)
        Jido.Composer.Workflow.DSL.__run_sync_loop__(__MODULE__, agent, directives)
      end
    end
  end

  @doc false
  def __run_sync_loop__(module, agent, directives) do
    case run_directives(module, agent, directives) do
      {:ok, agent} ->
        strat = Jido.Agent.Strategy.State.get(agent)
        {:ok, strat.machine.context}

      {:error, reason} ->
        {:error, reason}

      {:suspend, agent, _directive} ->
        strat = Jido.Agent.Strategy.State.get(agent)
        {:error, {:suspended, strat.pending_approval}}
    end
  end

  defp run_directives(_module, agent, []), do: check_terminal(agent)

  defp run_directives(module, agent, [directive | rest]) do
    case directive do
      %Jido.Agent.Directive.RunInstruction{instruction: instr, result_action: result_action} ->
        payload = execute_sync(instr)
        {agent, new_directives} = module.cmd(agent, {result_action, payload})
        run_directives(module, agent, new_directives ++ rest)

      %Jido.Agent.Directive.SpawnAgent{agent: child_module, tag: tag, opts: spawn_opts} ->
        payload = execute_child_sync(child_module, spawn_opts)

        {agent, new_directives} =
          module.cmd(agent, {:workflow_child_result, %{tag: tag, result: payload}})

        run_directives(module, agent, new_directives ++ rest)

      %Jido.Composer.Directive.SuspendForHuman{} = suspend ->
        {:suspend, agent, suspend}

      _other ->
        run_directives(module, agent, rest)
    end
  end

  defp execute_child_sync(child_module, spawn_opts) do
    context = Map.get(spawn_opts, :context, %{})
    child_agent = child_module.new()

    cond do
      function_exported?(child_module, :run_sync, 2) ->
        child_module.run_sync(child_agent, context)

      function_exported?(child_module, :query_sync, 3) ->
        query = Map.get(context, :query, "")
        child_module.query_sync(child_agent, query, context)

      true ->
        {:error, :agent_not_sync_runnable}
    end
  end

  defp execute_sync(%Jido.Instruction{action: action_module, params: params}) do
    case Jido.Exec.run(action_module, params, %{}, timeout: 0) do
      {:ok, result} ->
        %{status: :ok, result: result}

      {:ok, result, outcome} ->
        %{status: :ok, result: result, outcome: outcome}

      {:error, reason} ->
        %{status: :error, reason: reason}
    end
  end

  defp check_terminal(agent) do
    strat = Jido.Agent.Strategy.State.get(agent)

    case strat.status do
      :success -> {:ok, agent}
      :failure -> {:error, :workflow_failed}
      _ -> {:ok, agent}
    end
  end

  @doc false
  def __wrap_nodes__(nodes) when is_map(nodes) do
    Map.new(nodes, fn
      {state, {module, opts}} when is_atom(module) and is_list(opts) ->
        if agent_module?(module) do
          {state, {:agent, module, opts}}
        else
          {state, {:action, module}}
        end

      {state, module} when is_atom(module) ->
        if agent_module?(module) do
          {state, {:agent, module, []}}
        else
          {state, {:action, module}}
        end

      {state, other} ->
        {state, other}
    end)
  end

  defp agent_module?(module) do
    Code.ensure_loaded?(module) && function_exported?(module, :__agent_metadata__, 0)
  end

  @doc false
  def __validate__!(nodes, transitions, initial, terminal_states) do
    node_states = Map.keys(nodes)
    terminals = MapSet.new(terminal_states || [:done, :failed])

    transition_targets =
      transitions
      |> Map.values()
      |> Enum.uniq()

    # Errors: transition targets must be defined nodes or terminal states
    for target <- transition_targets do
      unless target in node_states or MapSet.member?(terminals, target) do
        raise CompileError,
          description:
            "Workflow transition targets state #{inspect(target)} " <>
              "which is neither a defined node nor a terminal state"
      end
    end

    unless initial in node_states do
      raise CompileError,
        description: "Workflow initial state #{inspect(initial)} is not defined in nodes"
    end

    # Warnings: unreachable states (not reachable from initial via transitions)
    reachable = reachable_states(initial, transitions)

    for state <- node_states do
      unless state in reachable do
        IO.warn(
          "Workflow state #{inspect(state)} is unreachable from initial state #{inspect(initial)}"
        )
      end
    end

    # Warnings: non-terminal states with no outgoing transitions (dead ends)
    # A state has outgoing transitions if there is an explicit {state, _} entry
    # or a wildcard {:_, _} entry. However, wildcard-only coverage still means
    # the state has no explicit success path, so we only count explicit sources.
    explicit_sources =
      transitions
      |> Map.keys()
      |> Enum.map(fn {state, _outcome} -> state end)
      |> Enum.reject(&(&1 == :_))
      |> MapSet.new()

    for state <- node_states do
      unless MapSet.member?(terminals, state) or MapSet.member?(explicit_sources, state) do
        IO.warn(
          "Workflow state #{inspect(state)} has no outgoing transitions and is not a terminal state"
        )
      end
    end

    :ok
  end

  defp reachable_states(initial, transitions) do
    do_reachable([initial], MapSet.new([initial]), transitions)
  end

  defp do_reachable([], visited, _transitions), do: MapSet.to_list(visited)

  defp do_reachable([current | rest], visited, transitions) do
    # Find all states reachable from current (including via wildcard source :_)
    next_states =
      transitions
      |> Enum.filter(fn {{source, _outcome}, _target} ->
        source == current or source == :_
      end)
      |> Enum.map(fn {_key, target} -> target end)
      |> Enum.reject(&MapSet.member?(visited, &1))

    new_visited = Enum.reduce(next_states, visited, &MapSet.put(&2, &1))
    do_reachable(rest ++ next_states, new_visited, transitions)
  end
end
