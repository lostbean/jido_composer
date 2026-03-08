defmodule Jido.Composer.Node do
  @moduledoc """
  Uniform context-in/context-out interface for workflow participants.

  Every participant in a composition — actions, agents, nested workflows —
  implements this behaviour. Nodes form an endomorphism monoid over context
  maps, composed via Kleisli arrows.

  ## Return Types

  - `{:ok, context}` — success with implicit outcome `:ok`
  - `{:ok, context, outcome}` — success with explicit outcome for FSM transitions
  - `{:error, reason}` — failure with implicit outcome `:error`

  ## Directive Generation

  The `to_directive/3` callback allows strategies to dispatch nodes polymorphically
  without pattern-matching on concrete struct types. Each node knows how to produce
  the appropriate directive(s) for execution given a flat context and keyword opts.

  Opts carry strategy-specific metadata (e.g. `:result_action`, `:tag`, `:meta`)
  so the node remains strategy-agnostic.

  The `to_tool_spec/1` callback lets nodes describe themselves as LLM tool definitions
  for orchestrator contexts. Nodes that cannot act as tools return `nil`.
  """

  @type context :: map()
  @type outcome :: atom()
  @type result :: {:ok, context()} | {:ok, context(), outcome()} | {:error, term()}

  @type directive_result ::
          {:ok, [struct()]}
          | {:ok, [struct()], keyword()}

  @callback run(node :: struct(), context :: context(), opts :: keyword()) :: result()
  @callback name(node :: struct()) :: String.t()
  @callback description(node :: struct()) :: String.t()
  @callback schema(node :: struct()) :: keyword() | nil
  @callback input_type(node :: struct()) :: :map | :text | :object | :any
  @callback output_type(node :: struct()) :: :map | :text | :object | :any

  @callback to_directive(node :: struct(), flat_context :: map(), opts :: keyword()) ::
              directive_result()

  @callback to_tool_spec(node :: struct()) :: map() | nil

  @optional_callbacks [schema: 1, input_type: 1, output_type: 1, to_directive: 3, to_tool_spec: 1]

  @doc "Returns `true` if `module` is a compiled `Jido.Agent` module."
  @spec agent_module?(module()) :: boolean()
  def agent_module?(module) do
    Code.ensure_loaded?(module) && function_exported?(module, :__agent_metadata__, 0)
  end

  @doc "Runs a child agent module synchronously via `run_sync/2` or `query_sync/3`."
  @spec execute_child_sync(module(), map()) :: {:ok, term()} | {:error, term()}
  def execute_child_sync(child_module, spawn_opts) do
    context = Map.get(spawn_opts, :context, %{})
    child_agent = child_module.new()

    cond do
      function_exported?(child_module, :run_sync, 2) ->
        child_module.run_sync(child_agent, context)

      function_exported?(child_module, :query_sync, 3) ->
        query = Map.get(context, :query, "")
        child_module.query_sync(child_agent, query, context)

      true ->
        {:error,
         Jido.Composer.Error.execution_error(
           "Agent module does not export run_sync/2 or query_sync/3",
           node: inspect(child_module)
         )}
    end
  end
end
