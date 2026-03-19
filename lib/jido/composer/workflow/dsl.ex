defmodule Jido.Composer.Workflow.DSL do
  @moduledoc """
  Compile-time macro for declarative workflow agent definitions.

  `use Jido.Composer.Workflow` generates a `Jido.Agent` module wired
  to the `Jido.Composer.Workflow.Strategy` with validated configuration.

  ## Terminal and Success States

  By default, workflows use `:done` and `:failed` as terminal states, with
  `:done` as the sole success state. Any terminal state not in `success_states`
  is treated as a failure.

  To customize, provide **both** `terminal_states` and `success_states`:

      terminal_states: [:completed, :errored, :cancelled, :timed_out],
      success_states: [:completed]

  Providing only one without the other raises a compile error — this ensures
  the success/failure classification is always explicit.

  On failure, the `error_reason` is the original error from the failing node.
  When no node error was captured (e.g., a direct transition to `:cancelled`),
  the terminal state atom itself becomes the error reason.

  ## Examples

      # Using convention defaults (:done/:failed)
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

      # Custom terminal states with explicit success classification
      defmodule ApprovalPipeline do
        use Jido.Composer.Workflow,
          name: "approval_pipeline",
          nodes: %{process: ProcessAction, review: ReviewAction},
          transitions: %{
            {:process, :ok}       => :review,
            {:review, :approved}  => :completed,
            {:review, :rejected}  => :rejected,
            {:_, :error}          => :errored
          },
          initial: :process,
          terminal_states: [:completed, :rejected, :errored],
          success_states: [:completed]
      end
  """

  defmacro __using__(opts) do
    name = Keyword.fetch!(opts, :name)
    description = Keyword.get(opts, :description, "Workflow: #{name}")
    schema = Keyword.get(opts, :schema, [])
    initial = Keyword.fetch!(opts, :initial)
    terminal_states = Keyword.get(opts, :terminal_states)
    success_states = Keyword.get(opts, :success_states)
    ambient_keys = Keyword.get(opts, :ambient, [])
    fork_fns = Keyword.get(opts, :fork_fns, %{})

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
      @__wf_success_states__ unquote(Macro.escape(success_states))

      # Wrap bare action modules: MyAction -> {:action, MyAction}
      @__wf_nodes__ Jido.Composer.Workflow.DSL.__wrap_nodes__(@__wf_nodes_raw__)

      # Validate configuration
      Jido.Composer.Workflow.DSL.__validate__!(
        @__wf_nodes_raw__,
        @__wf_transitions__,
        @__wf_initial__,
        @__wf_terminal_states__,
        @__wf_success_states__
      )

      # Build strategy opts — when neither terminal_states nor success_states is
      # provided, use convention defaults. When both are provided, use as given.
      # Providing one without the other is caught by __validate__!.
      @__wf_strategy_opts__ [
        nodes: @__wf_nodes__,
        transitions: @__wf_transitions__,
        initial: @__wf_initial__,
        ambient: unquote(ambient_keys),
        fork_fns: unquote(Macro.escape(fork_fns)),
        terminal_states: @__wf_terminal_states__ || [:done, :failed],
        success_states: @__wf_success_states__ || [:done]
      ]

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

      @doc """
      Runs the workflow synchronously, blocking until terminal state.

      Returns `{:ok, result_map}` on success or `{:error, reason}` on failure.
      The `reason` preserves the original error from the failing node — typically
      a `Jido.Action.Error` struct, a child agent's error, or a transition error.
      Callers can pattern-match on the error type for specific handling.

      If the workflow suspends (e.g., at a HumanNode), returns
      `{:error, {:suspended, suspension}}`.
      """
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

        result =
          case strat.machine.context do
            %Jido.Composer.Context{} = ctx -> Jido.Composer.Context.to_clean_map(ctx)
            map when is_map(map) -> map
          end

        {:ok, result}

      {:error, reason} ->
        {:error, reason}

      {:suspend, _agent, directive} ->
        {:error, {:suspended, directive.suspension}}
    end
  end

  defp run_directives(_module, agent, []), do: check_terminal(agent)

  defp run_directives(module, agent, [directive | rest]) do
    case directive do
      %Jido.Agent.Directive.RunInstruction{instruction: instr, result_action: result_action} ->
        payload = execute_sync(instr)
        {agent, new_directives} = module.cmd(agent, {result_action, payload})
        run_directives(module, agent, new_directives ++ rest)

      %Jido.Agent.Directive.SpawnAgent{
        agent: child_module,
        tag: tag,
        opts: spawn_opts,
        meta: meta
      } ->
        # Run child with parent OTel context attached so its AGENT span parents
        # under the parent's TOOL span (Gap 7 fix)
        payload =
          Jido.Composer.OtelCtx.with_parent_context(meta[:otel_parent_ctx], fn ->
            Jido.Composer.Node.execute_child_sync(child_module, spawn_opts)
          end)

        {agent, new_directives} =
          module.cmd(agent, {:workflow_child_result, %{tag: tag, result: payload}})

        run_directives(module, agent, new_directives ++ rest)

      %Jido.Composer.Directive.FanOutBranch{} = _first_branch ->
        # Collect all FanOutBranch directives from this batch
        {fan_out_directives, remaining} =
          Enum.split_with([directive | rest], fn
            %Jido.Composer.Directive.FanOutBranch{} -> true
            _ -> false
          end)

        branch_results = execute_fan_out_branches(fan_out_directives)

        # Feed each result back through cmd/3, accumulating directives from the last call
        {agent, final_directives} =
          Enum.reduce(branch_results, {agent, []}, fn {branch_name, result}, {acc, _dirs} ->
            module.cmd(acc, {:fan_out_branch_result, %{branch_name: branch_name, result: result}})
          end)

        run_directives(module, agent, final_directives ++ remaining)

      %Jido.Composer.Directive.Suspend{} = suspend ->
        {:suspend, agent, suspend}

      _other ->
        run_directives(module, agent, rest)
    end
  end

  defp execute_fan_out_branches(fan_out_directives) do
    timeout =
      case List.first(fan_out_directives) do
        %{timeout: t} when is_integer(t) -> t
        _ -> 30_000
      end

    fan_out_directives
    |> Task.async_stream(
      fn %Jido.Composer.Directive.FanOutBranch{} = branch ->
        result = execute_fan_out_branch(branch)
        {branch.branch_name, result}
      end,
      timeout: timeout,
      on_timeout: :kill_task,
      ordered: true,
      max_concurrency: length(fan_out_directives)
    )
    |> Enum.zip(fan_out_directives)
    |> Enum.map(fn
      {{:ok, {name, result}}, _branch} -> {name, result}
      {{:exit, reason}, branch} -> {branch.branch_name, {:error, {:branch_crashed, reason}}}
    end)
  end

  defp execute_fan_out_branch(%Jido.Composer.Directive.FanOutBranch{
         instruction: {:function, fun, context}
       }) do
    fun.(context)
  end

  defp execute_fan_out_branch(%Jido.Composer.Directive.FanOutBranch{
         instruction: %Jido.Instruction{} = instr
       }) do
    case execute_sync(instr) do
      %{status: :ok, result: result} -> {:ok, result}
      %{status: :error, result: %{error: reason}} -> {:error, reason}
    end
  end

  defp execute_fan_out_branch(%Jido.Composer.Directive.FanOutBranch{spawn_agent: spawn_info})
       when not is_nil(spawn_info) do
    Jido.Composer.Node.execute_child_sync(spawn_info.agent, spawn_info.opts)
  end

  defp execute_sync(%Jido.Instruction{action: action_module, params: params}) do
    case Jido.Exec.run(action_module, params, %{}, timeout: 0) do
      {:ok, result} ->
        %{status: :ok, result: result}

      {:ok, result, outcome} ->
        %{status: :ok, result: result, outcome: outcome}

      {:error, reason} ->
        %{status: :error, result: %{error: reason}}
    end
  end

  defp check_terminal(agent) do
    strat = Jido.Agent.Strategy.State.get(agent)

    case strat.status do
      :success -> {:ok, agent}
      :failure -> {:error, Map.get(strat, :error_reason, :workflow_failed)}
      _ -> {:ok, agent}
    end
  end

  @doc false
  def __wrap_nodes__(nodes) when is_map(nodes) do
    Map.new(nodes, fn
      {state, {module, opts}} when is_atom(module) and is_list(opts) ->
        if Jido.Composer.Node.agent_module?(module) do
          {state, {:agent, module, opts}}
        else
          {state, {:action, module}}
        end

      {state, module} when is_atom(module) ->
        if Jido.Composer.Node.agent_module?(module) do
          {state, {:agent, module, []}}
        else
          {state, {:action, module}}
        end

      {state, other} ->
        {state, other}
    end)
  end

  @reserved_outcomes [:suspend]

  @doc false
  def __validate__!(nodes, transitions, initial, terminal_states, success_states) do
    node_states = Map.keys(nodes)
    terminals = MapSet.new(terminal_states || [:done, :failed])

    # Enforce pairing: terminal_states and success_states must be provided together
    case {terminal_states, success_states} do
      {nil, nil} ->
        :ok

      {_, nil} ->
        raise CompileError,
          description:
            "terminal_states requires success_states — " <>
              "specify which terminal states are successes (e.g., success_states: [:done])"

      {nil, _} ->
        raise CompileError,
          description:
            "success_states requires terminal_states — " <>
              "specify all terminal states (e.g., terminal_states: [:done, :failed])"

      {_, _} ->
        success_set = MapSet.new(success_states)
        invalid = MapSet.difference(success_set, terminals)

        unless MapSet.size(invalid) == 0 do
          raise CompileError,
            description:
              "success_states #{inspect(MapSet.to_list(invalid))} " <>
                "are not in terminal_states #{inspect(MapSet.to_list(terminals))}"
        end
    end

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

    # Warn about reserved outcomes used in transitions
    for {{state, outcome}, target} <- transitions, outcome in @reserved_outcomes do
      IO.warn(
        "Workflow transition {#{inspect(state)}, #{inspect(outcome)}} => #{inspect(target)} " <>
          "is unreachable — #{inspect(outcome)} is a reserved outcome intercepted by the strategy"
      )
    end

    # Warn if no transitions lead to any terminal state
    targets_set = MapSet.new(transition_targets)

    if MapSet.disjoint?(targets_set, terminals) do
      IO.warn(
        "No transitions target terminal states #{inspect(MapSet.to_list(terminals))}. " <>
          "Workflow will never complete. Specify terminal_states: [...] if using custom names."
      )
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
