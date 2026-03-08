defmodule Jido.Composer.Node.AgentNode do
  @moduledoc """
  Wraps a `Jido.Agent` module as a Node.

  AgentNode carries per-instance configuration for how the agent should be
  spawned and communicated with. It supports three communication modes:

  - `:sync` (default) — spawn agent, send context as signal, await result
  - `:async` — spawn agent, return immediately with `:pending` outcome
  - `:streaming` — spawn agent, subscribe to state transitions at specified states

  AgentNode delegates metadata (name, description, schema) to the wrapped
  agent module. Scoping of results is the responsibility of the composition
  layer (Machine/Strategy), not the node.
  """

  alias Jido.Composer.Error

  @behaviour Jido.Composer.Node

  @valid_modes [:sync, :async, :streaming]
  @default_timeout 30_000

  @enforce_keys [:agent_module]
  defstruct [:agent_module, :signal_type, :on_state, mode: :sync, opts: []]

  @type mode :: :sync | :async | :streaming

  @type t :: %__MODULE__{
          agent_module: module(),
          mode: mode(),
          opts: keyword(),
          signal_type: String.t() | nil,
          on_state: [atom()] | nil
        }

  @spec new(module(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(agent_module, config \\ []) do
    mode = Keyword.get(config, :mode, :sync)

    cond do
      mode not in @valid_modes ->
        {:error, "invalid mode #{inspect(mode)}, must be one of #{inspect(@valid_modes)}"}

      not Jido.Composer.Node.agent_module?(agent_module) ->
        {:error, "#{inspect(agent_module)} is not a valid Jido.Agent module"}

      true ->
        {:ok,
         %__MODULE__{
           agent_module: agent_module,
           mode: mode,
           opts: Keyword.get(config, :opts, []),
           signal_type: Keyword.get(config, :signal_type),
           on_state: Keyword.get(config, :on_state)
         }}
    end
  end

  @impl true
  @spec run(t(), map(), keyword()) :: Jido.Composer.Node.result()
  def run(node, context, opts \\ [])

  def run(%__MODULE__{mode: :sync} = node, context, _opts) do
    agent = node.agent_module.new()

    cond do
      function_exported?(node.agent_module, :run_sync, 2) ->
        case node.agent_module.run_sync(agent, context) do
          {:ok, result} when is_map(result) -> {:ok, result}
          {:error, reason} -> {:error, reason}
        end

      function_exported?(node.agent_module, :query_sync, 3) ->
        query = Map.get(context, :query, Map.get(context, "query", ""))

        case node.agent_module.query_sync(agent, query, context) do
          {:ok, result} -> {:ok, %{result: result}}
          {:error, reason} -> {:error, reason}
        end

      true ->
        {:error,
         Error.execution_error(
           "Agent module does not export run_sync/2 or query_sync/3",
           node: inspect(node.agent_module)
         )}
    end
  end

  def run(%__MODULE__{mode: mode}, _context, _opts) when mode in [:async, :streaming] do
    {:error,
     Error.execution_error(
       "AgentNode mode #{inspect(mode)} is not directly runnable — use directive-based execution",
       details: %{mode: mode}
     )}
  end

  @impl true
  @spec name(t()) :: String.t()
  def name(%__MODULE__{agent_module: mod}), do: mod.name()

  @impl true
  @spec description(t()) :: String.t()
  def description(%__MODULE__{agent_module: mod}), do: mod.description()

  @impl true
  @spec schema(t()) :: term()
  def schema(%__MODULE__{agent_module: mod}), do: mod.schema()

  @impl true
  @spec to_directive(t(), map(), keyword()) :: Jido.Composer.Node.directive_result()
  def to_directive(%__MODULE__{agent_module: agent_module, opts: opts}, flat_context, kw_opts) do
    tag = Keyword.fetch!(kw_opts, :tag)
    context = Keyword.get(kw_opts, :structured_context)

    child_flat =
      if context do
        context
        |> Jido.Composer.Context.fork_for_child()
        |> Jido.Composer.Context.to_flat_map()
      else
        flat_context
      end

    # Merge tool args if provided (orchestrator context)
    child_flat =
      case Keyword.get(kw_opts, :tool_args) do
        nil -> child_flat
        args -> Map.merge(child_flat, args)
      end

    directive = %Jido.Agent.Directive.SpawnAgent{
      tag: tag,
      agent: agent_module,
      opts: Map.new(opts) |> Map.put(:context, child_flat)
    }

    {:ok, [directive]}
  end

  @impl true
  @spec to_tool_spec(t()) :: map()
  def to_tool_spec(%__MODULE__{agent_module: mod}) do
    schema = mod.schema()

    parameter_schema =
      if is_list(schema) do
        Jido.Action.Tool.build_parameters_schema(schema)
      else
        %{"type" => "object", "properties" => %{}, "required" => []}
      end

    %{
      name: mod.name(),
      description: mod.description(),
      parameter_schema: parameter_schema
    }
  end

  @spec timeout(t()) :: pos_integer()
  def timeout(%__MODULE__{opts: opts}), do: Keyword.get(opts, :timeout, @default_timeout)
end
