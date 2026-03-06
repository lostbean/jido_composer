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

      not agent_module?(agent_module) ->
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
        {:error, :agent_not_sync_runnable}
    end
  end

  def run(%__MODULE__{mode: mode}, _context, _opts) when mode in [:async, :streaming] do
    {:error, {:not_directly_runnable, mode}}
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

  @spec timeout(t()) :: pos_integer()
  def timeout(%__MODULE__{opts: opts}), do: Keyword.get(opts, :timeout, @default_timeout)

  defp agent_module?(module) do
    Code.ensure_loaded?(module) && function_exported?(module, :__agent_metadata__, 0)
  end
end
