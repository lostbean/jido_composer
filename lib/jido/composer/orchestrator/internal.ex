defmodule Jido.Composer.Orchestrator.Internal do
  @moduledoc false
  # Private helpers shared by Orchestrator.Strategy and Orchestrator.Configure.

  alias Jido.Composer.Node.ActionNode
  alias Jido.Composer.Node.AgentNode
  alias Jido.Composer.Orchestrator.AgentTool

  @spec build_nodes([module() | {module(), keyword()} | struct()]) ::
          %{String.t() => struct()}
  def build_nodes(modules) when is_list(modules) do
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

  @spec build_termination_tool(module() | nil, [map()], %{String.t() => atom()}) ::
          {[map()], %{String.t() => atom()}, String.t() | nil, module() | nil}
  def build_termination_tool(nil, tools, name_atoms), do: {tools, name_atoms, nil, nil}

  def build_termination_tool(mod, tools, name_atoms) when is_atom(mod) do
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

  @spec extract_all_schema_keys(%{String.t() => struct()}) ::
          %{String.t() => MapSet.t(atom())}
  def extract_all_schema_keys(nodes) do
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
