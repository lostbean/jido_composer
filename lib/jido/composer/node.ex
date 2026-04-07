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

  @doc "Returns `true` if `module` declares the `Jido.Composer.Node` behaviour."
  @spec node?(module()) :: boolean()
  def node?(module) do
    match?({:module, _}, Code.ensure_compiled(module)) &&
      function_exported?(module, :__info__, 1) &&
      __MODULE__ in (module.__info__(:attributes)
                     |> Keyword.get_values(:behaviour)
                     |> List.flatten())
  end

  @doc """
  Extracts the name from a Node struct.

  Validates that the struct's module implements the Node behaviour before
  calling `name/1`. Raises `ArgumentError` if it does not.

  Used by `AgentTool`, `Configure`, and `Strategy` to handle custom Node
  structs without duplicating the dispatch + validation logic.
  """
  @spec dispatch_name(struct()) :: String.t()
  def dispatch_name(%mod{} = node) when is_atom(mod) do
    unless node?(mod) do
      raise ArgumentError, "#{inspect(mod)} does not implement the Node behaviour"
    end

    mod.name(node)
  end

  @doc "Returns `true` if `module` is a compiled `Jido.Agent` module."
  @spec agent_module?(module()) :: boolean()
  def agent_module?(module) do
    match?({:module, _}, Code.ensure_compiled(module)) &&
      function_exported?(module, :__agent_metadata__, 0)
  end

  @doc """
  Returns `true` if `module` is a Jido.AI agent (exports `ask_sync/3`).

  Jido.AI agents require a running AgentServer process and communicate
  via `ask_sync(pid, query, opts)` rather than struct-based `run_sync/2`.
  """
  @spec ai_agent_module?(module()) :: boolean()
  def ai_agent_module?(module) do
    agent_module?(module) && function_exported?(module, :ask_sync, 3) &&
      not function_exported?(module, :run_sync, 2) &&
      not function_exported?(module, :query_sync, 3)
  end

  @doc """
  Runs a child agent module synchronously.

  Supports three agent types:
  - Composer Workflow agents (`run_sync/2`)
  - Composer Orchestrator agents (`query_sync/3`)
  - Jido.AI agents (`ask_sync/3` via a temporary AgentServer process)
  """
  @spec execute_child_sync(module(), map()) :: {:ok, term()} | {:error, term()}
  def execute_child_sync(child_module, spawn_opts) do
    context = Map.get(spawn_opts, :context, %{})

    cond do
      function_exported?(child_module, :run_sync, 2) ->
        child_agent = child_module.new()
        child_module.run_sync(child_agent, context)

      function_exported?(child_module, :query_sync, 3) ->
        child_agent = child_module.new()
        query = Map.get(context, :query, "")

        case child_module.query_sync(child_agent, query, context) do
          {:ok, _agent, result} -> {:ok, result}
          {:suspended, _agent, suspension} -> {:error, {:suspended, suspension}}
          {:error, reason} -> {:error, reason}
        end

      function_exported?(child_module, :ask_sync, 3) ->
        execute_ai_agent_sync(child_module, context)

      true ->
        {:error,
         Jido.Composer.Error.execution_error(
           "Agent module does not export run_sync/2, query_sync/3, or ask_sync/3",
           node: inspect(child_module)
         )}
    end
  end

  @doc false
  @spec execute_ai_agent_sync(module(), map()) :: {:ok, term()} | {:error, term()}
  def execute_ai_agent_sync(child_module, context) do
    query = Map.get(context, :query, Map.get(context, "query", ""))
    timeout = Map.get(context, :timeout, 30_000)

    with {:ok, pid} <- start_ai_agent(child_module) do
      try do
        child_module.ask_sync(pid, query, timeout: timeout)
      after
        stop_ai_agent(pid)
      end
    end
  end

  defp start_ai_agent(child_module) do
    cond do
      # Prefer start_link for direct linkage (no supervisor required)
      function_exported?(child_module, :start_link, 1) ->
        child_module.start_link([])

      Code.ensure_loaded?(Jido.AgentServer) &&
          function_exported?(Jido.AgentServer, :start_link, 1) ->
        Jido.AgentServer.start_link(agent: child_module)

      true ->
        {:error,
         Jido.Composer.Error.execution_error(
           "Cannot start AI agent — module must export start_link/1 or Jido.AgentServer must be available",
           node: inspect(child_module)
         )}
    end
  end

  defp stop_ai_agent(pid) when is_pid(pid) do
    ref = Process.monitor(pid)

    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)

    # Wait for the process (and its supervised children) to fully terminate.
    # AgentServer spawns child workers under a DynamicSupervisor; the parent
    # stop returns before child cleanup is complete, causing Registry collisions
    # if a new agent starts immediately after.
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} ->
        Process.sleep(500)
    after
      5_000 -> Process.demonitor(ref, [:flush])
    end
  catch
    :exit, _ -> :ok
  end

  defp stop_ai_agent(_), do: :ok
end
