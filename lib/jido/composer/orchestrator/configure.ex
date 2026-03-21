defmodule Jido.Composer.Orchestrator.Configure do
  @moduledoc """
  Runtime configuration API for orchestrator agents.

  Orchestrators are defined declaratively via the DSL, but at runtime you
  often need to override fields before calling `query_sync/3` — dynamic
  system prompts, RBAC-filtered tools, per-mode model selection, pre-loaded
  conversation history, or test cassette injection.

  `configure/2` applies overrides after `new/0` but before `query_sync/3`.
  It handles internal rebuilds (nodes → tools → name_atoms → schema_keys)
  so callers never touch strategy internals.

  ## Usage

      agent = MyOrchestrator.new()

      agent = MyOrchestrator.configure(agent,
        system_prompt: dynamic_prompt,
        nodes: filtered_action_modules,
        model: "anthropic:claude-sonnet-4-20250514",
        temperature: 0.7,
        max_tokens: 8192,
        req_options: [plug: {ReqCassette, cassette: "test"}],
        conversation: preloaded_context
      )

      {:ok, _agent, result} = MyOrchestrator.query_sync(agent, user_message, ambient)

  ## Read-Filter-Write Pattern

  Use `get_action_modules/1` and `get_termination_module/1` to inspect the
  current configuration, filter it, then write it back:

      # Read what the DSL declared
      modules = MyOrchestrator.get_action_modules(agent)
      term_mod = MyOrchestrator.get_termination_module(agent)

      # Filter by user role
      filtered = Enum.filter(modules, &my_rbac_check/1)

      # Write back — handles node/tool/atom rebuild + termination tool dedup
      agent = MyOrchestrator.configure(agent, nodes: filtered)

  ## Overridable Keys

  | Key              | Type                 | Behaviour                                            |
  | ---------------- | -------------------- | ---------------------------------------------------- |
  | `:system_prompt`  | `String.t()`         | Replaces the DSL system prompt                       |
  | `:nodes`          | `[module()]`         | Rebuilds nodes, tools, name_atoms, schema_keys       |
  | `:model`          | `String.t()`         | Replaces the model identifier                        |
  | `:temperature`    | `float()`            | Replaces the temperature                             |
  | `:max_tokens`     | `integer()`          | Replaces max tokens                                  |
  | `:max_iterations` | `integer()`          | Replaces max ReAct loop iterations                   |
  | `:req_options`    | `keyword()`          | Replaces HTTP options                                |
  | `:conversation`   | `ReqLLM.Context.t()` | Sets or replaces conversation context                |
  """

  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.Composer.Node.ActionNode
  alias Jido.Composer.Node.AgentNode
  alias Jido.Composer.Orchestrator.AgentTool

  @configurable_keys ~w(system_prompt nodes model temperature max_tokens max_iterations req_options conversation)a

  @doc """
  Applies runtime overrides to an orchestrator agent's strategy state.

  Accepts a keyword list with any combination of:

    * `:system_prompt` — replaces the system prompt
    * `:nodes` — list of action/agent modules; rebuilds ActionNode/AgentNode
      structs, tools, name_atoms, and schema_keys internally. Handles
      termination tool deduplication automatically.
    * `:model` — replaces the model identifier
    * `:temperature` — replaces the temperature
    * `:max_tokens` — replaces max tokens
    * `:max_iterations` — replaces max ReAct loop iterations
    * `:req_options` — replaces HTTP options (e.g. for cassette injection)
    * `:conversation` — sets or replaces conversation context

  Returns the updated agent.
  """
  @spec configure(Jido.Agent.t(), keyword()) :: Jido.Agent.t()
  def configure(%Jido.Agent{} = agent, overrides) when is_list(overrides) do
    StratState.update(agent, fn state ->
      Enum.reduce(overrides, state, fn
        {:nodes, modules}, state when is_list(modules) ->
          apply_nodes_override(state, modules)

        {key, value}, state when key in @configurable_keys ->
          Map.put(state, key, value)

        {key, _value}, _state ->
          raise ArgumentError,
                "unknown configure key #{inspect(key)}. " <>
                  "Allowed keys: #{inspect(@configurable_keys)}"
      end)
    end)
  end

  @doc """
  Returns the list of action/agent modules currently configured as nodes.
  """
  @spec get_action_modules(Jido.Agent.t()) :: [module()]
  def get_action_modules(%Jido.Agent{} = agent) do
    state = StratState.get(agent, %{})

    state
    |> Map.get(:nodes, %{})
    |> Map.values()
    |> Enum.map(fn
      %ActionNode{action_module: mod} -> mod
      %AgentNode{agent_module: mod} -> mod
      %mod{} -> mod
    end)
  end

  @doc """
  Returns the termination tool module, or `nil` if none is configured.
  """
  @spec get_termination_module(Jido.Agent.t()) :: module() | nil
  def get_termination_module(%Jido.Agent{} = agent) do
    state = StratState.get(agent, %{})
    Map.get(state, :termination_tool_mod)
  end

  # -- Private --

  defp apply_nodes_override(state, modules) do
    nodes = build_nodes(modules)
    tools = Enum.map(nodes, fn {_name, node} -> AgentTool.to_tool(node) end)
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    name_atoms = Map.new(nodes, fn {name, _node} -> {name, String.to_atom(name)} end)
    schema_keys = extract_all_schema_keys(nodes)

    # Re-apply termination tool dedup using existing termination_tool_mod
    {tools, name_atoms, term_name, term_mod} =
      build_termination_tool(Map.get(state, :termination_tool_mod), tools, name_atoms)

    state
    |> Map.put(:nodes, nodes)
    |> Map.put(:tools, tools)
    |> Map.put(:name_atoms, name_atoms)
    |> Map.put(:schema_keys, schema_keys)
    |> Map.put(:termination_tool_name, term_name)
    |> Map.put(:termination_tool_mod, term_mod)
  end

  defp build_nodes(modules) when is_list(modules) do
    Map.new(modules, fn
      {mod, opts} when is_atom(mod) and is_list(opts) ->
        if Jido.Composer.Node.agent_module?(mod) do
          {:ok, node} = AgentNode.new(mod, opts)
          {AgentNode.name(node), node}
        else
          {:ok, node} = ActionNode.new(mod, opts)
          {ActionNode.name(node), node}
        end

      mod when is_atom(mod) ->
        if Jido.Composer.Node.agent_module?(mod) do
          {:ok, node} = AgentNode.new(mod)
          {AgentNode.name(node), node}
        else
          {:ok, node} = ActionNode.new(mod)
          {ActionNode.name(node), node}
        end

      %ActionNode{} = node ->
        {ActionNode.name(node), node}

      %AgentNode{} = node ->
        {AgentNode.name(node), node}

      %_mod{} = node ->
        {Jido.Composer.Node.dispatch_name(node), node}
    end)
  end

  defp build_termination_tool(nil, tools, name_atoms), do: {tools, name_atoms, nil, nil}

  defp build_termination_tool(mod, tools, name_atoms) when is_atom(mod) do
    tool = AgentTool.to_tool(mod)
    name = mod.name()
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    updated_atoms = Map.put(name_atoms, name, String.to_atom(name))

    tools =
      if Enum.any?(tools, fn t -> t.name == tool.name end) do
        tools
      else
        tools ++ [tool]
      end

    {tools, updated_atoms, name, mod}
  end

  defp extract_all_schema_keys(nodes) do
    Map.new(nodes, fn {name, node} ->
      schema = node.__struct__.schema(node)

      keys =
        case schema do
          list when is_list(list) ->
            Enum.map(list, fn
              {key, _opts} when is_atom(key) -> key
              key when is_atom(key) -> key
            end)
            |> MapSet.new()

          _ ->
            MapSet.new()
        end

      {name, keys}
    end)
  end
end
