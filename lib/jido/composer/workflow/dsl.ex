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
    end
  end

  @doc false
  def __wrap_nodes__(nodes) when is_map(nodes) do
    Map.new(nodes, fn
      {state, {module, opts}} when is_atom(module) and is_list(opts) ->
        {state, {:agent, module, opts}}

      {state, module} when is_atom(module) ->
        {state, {:action, module}}

      {state, other} ->
        {state, other}
    end)
  end

  @doc false
  def __validate__!(nodes, transitions, initial, terminal_states) do
    node_states = Map.keys(nodes)
    terminals = MapSet.new(terminal_states || [:done, :failed])

    transition_targets =
      transitions
      |> Map.values()
      |> Enum.uniq()

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

    :ok
  end
end
