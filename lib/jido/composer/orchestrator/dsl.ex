defmodule Jido.Composer.Orchestrator.DSL do
  @moduledoc """
  Compile-time macro for declarative orchestrator agent definitions.

  `use Jido.Composer.Orchestrator` generates a `Jido.Agent` module wired
  to the `Jido.Composer.Orchestrator.Strategy` with validated configuration.

  ## Example

      defmodule MyCoordinator do
        use Jido.Composer.Orchestrator,
          name: "coordinator",
          model: "anthropic:claude-sonnet-4-20250514",
          nodes: [ResearchAction, WriterAction],
          system_prompt: "You coordinate research and writing.",
          max_iterations: 15
      end
  """

  defmacro __using__(opts) do
    name = Keyword.fetch!(opts, :name)
    description = Keyword.get(opts, :description, "Orchestrator: #{name}")
    schema = Keyword.get(opts, :schema, [])
    llm = Keyword.get(opts, :llm, Jido.Composer.Orchestrator.LLM)
    model = Keyword.get(opts, :model, nil)
    nodes_ast = Keyword.fetch!(opts, :nodes)
    system_prompt = Keyword.get(opts, :system_prompt, nil)
    max_iterations = Keyword.get(opts, :max_iterations, 10)
    req_options = Keyword.get(opts, :req_options, [])
    rejection_policy = Keyword.get(opts, :rejection_policy)

    orchestrator_routes = Jido.Composer.Orchestrator.Strategy.signal_routes(%{})

    quote do
      @__orch_nodes_raw__ unquote(nodes_ast)

      {plain_nodes, gated_names} =
        Jido.Composer.Orchestrator.DSL.__parse_nodes__(@__orch_nodes_raw__)

      @__orch_nodes__ plain_nodes
      @__orch_gated_nodes__ gated_names

      @__orch_strategy_opts__ [
                                nodes: @__orch_nodes__,
                                llm_module: unquote(llm),
                                model: unquote(model),
                                system_prompt: unquote(system_prompt),
                                max_iterations: unquote(max_iterations),
                                req_options: unquote(req_options)
                              ] ++
                                if(@__orch_gated_nodes__ != [],
                                  do: [gated_nodes: @__orch_gated_nodes__],
                                  else: []
                                ) ++
                                if(unquote(rejection_policy) != nil,
                                  do: [rejection_policy: unquote(rejection_policy)],
                                  else: []
                                )

      use Jido.Agent,
        name: unquote(name),
        description: unquote(description),
        schema: unquote(Macro.escape(schema)),
        strategy: {Jido.Composer.Orchestrator.Strategy, @__orch_strategy_opts__},
        signal_routes: unquote(Macro.escape(orchestrator_routes))

      @doc "Sends a query to the orchestrator and returns directives for the ReAct loop."
      @spec query(Jido.Agent.t(), String.t(), map()) :: Jido.Agent.cmd_result()
      def query(%Jido.Agent{} = agent, query, context \\ %{}) when is_binary(query) do
        __MODULE__.cmd(agent, {:orchestrator_start, Map.put(context, :query, query)})
      end

      @doc "Runs the orchestrator synchronously, blocking until final answer."
      @spec query_sync(Jido.Agent.t(), String.t(), map()) :: {:ok, String.t()} | {:error, term()}
      def query_sync(%Jido.Agent{} = agent, query, context \\ %{}) when is_binary(query) do
        {agent, directives} = query(agent, query, context)
        Jido.Composer.Orchestrator.DSL.__query_sync_loop__(__MODULE__, agent, directives)
      end
    end
  end

  @doc false
  def __parse_nodes__(nodes) when is_list(nodes) do
    Enum.reduce(nodes, {[], []}, fn
      {mod, opts}, {plain, gated} when is_atom(mod) and is_list(opts) ->
        name = get_node_name(mod)
        is_gated = Keyword.get(opts, :requires_approval, false)
        remaining_opts = Keyword.delete(opts, :requires_approval)

        node_entry = if remaining_opts == [], do: mod, else: {mod, remaining_opts}
        gated = if is_gated, do: [name | gated], else: gated
        {[node_entry | plain], gated}

      mod, {plain, gated} when is_atom(mod) ->
        {[mod | plain], gated}
    end)
    |> then(fn {plain, gated} -> {Enum.reverse(plain), Enum.reverse(gated)} end)
  end

  @doc false
  def __query_sync_loop__(module, agent, directives) do
    run_orch_directives(module, agent, directives)
  end

  defp run_orch_directives(_module, agent, []) do
    strat = Jido.Agent.Strategy.State.get(agent)

    case strat.status do
      :completed -> {:ok, strat.result}
      :error -> {:error, strat.result}
      _ -> {:error, :unexpected_state}
    end
  end

  defp run_orch_directives(module, agent, [directive | rest]) do
    case directive do
      %Jido.Agent.Directive.RunInstruction{
        instruction: instr,
        result_action: result_action,
        meta: meta
      } ->
        payload = execute_orch_instruction(instr) |> Map.put(:meta, meta || %{})
        {agent, new_directives} = module.cmd(agent, {result_action, payload})
        run_orch_directives(module, agent, new_directives ++ rest)

      _other ->
        run_orch_directives(module, agent, rest)
    end
  end

  defp execute_orch_instruction(%Jido.Instruction{action: action_module, params: params}) do
    case Jido.Exec.run(action_module, params, %{}, timeout: 0) do
      {:ok, result} -> %{status: :ok, result: result}
      {:error, reason} -> %{status: :error, result: %{error: reason}}
    end
  end

  defp get_node_name(mod) do
    Code.ensure_loaded!(mod)

    cond do
      function_exported?(mod, :name, 0) -> mod.name()
      true -> mod |> Module.split() |> List.last() |> Macro.underscore()
    end
  end
end
