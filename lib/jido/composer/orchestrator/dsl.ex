defmodule Jido.Composer.Orchestrator.DSL do
  @moduledoc """
  Compile-time macro for declarative orchestrator agent definitions.

  `use Jido.Composer.Orchestrator` generates a `Jido.Agent` module wired
  to the `Jido.Composer.Orchestrator.Strategy` with validated configuration.

  ## Example

      defmodule MyCoordinator do
        use Jido.Composer.Orchestrator,
          name: "coordinator",
          llm: MyApp.ClaudeLLM,
          nodes: [ResearchAction, WriterAction],
          system_prompt: "You coordinate research and writing.",
          max_iterations: 15
      end
  """

  defmacro __using__(opts) do
    name = Keyword.fetch!(opts, :name)
    description = Keyword.get(opts, :description, "Orchestrator: #{name}")
    schema = Keyword.get(opts, :schema, [])
    llm = Keyword.fetch!(opts, :llm)
    nodes_ast = Keyword.fetch!(opts, :nodes)
    system_prompt = Keyword.get(opts, :system_prompt, nil)
    max_iterations = Keyword.get(opts, :max_iterations, 10)
    req_options = Keyword.get(opts, :req_options, [])

    orchestrator_routes = Jido.Composer.Orchestrator.Strategy.signal_routes(%{})

    quote do
      @__orch_nodes__ unquote(nodes_ast)

      @__orch_strategy_opts__ [
        nodes: @__orch_nodes__,
        llm_module: unquote(llm),
        system_prompt: unquote(system_prompt),
        max_iterations: unquote(max_iterations),
        req_options: unquote(req_options)
      ]

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
    end
  end
end
