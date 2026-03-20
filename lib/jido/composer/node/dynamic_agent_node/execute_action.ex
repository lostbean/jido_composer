defmodule Jido.Composer.Node.DynamicAgentNode.ExecuteAction do
  @moduledoc false
  # Internal action used by DynamicAgentNode.to_directive/3.
  # Receives the node struct and context via params and delegates
  # to DynamicAgentNode.run/3.

  use Jido.Action,
    name: "dynamic_agent_node_execute",
    description: "Executes a DynamicAgentNode (internal)",
    schema: []

  alias Jido.Composer.Node.DynamicAgentNode

  def run(%{__node__: %DynamicAgentNode{} = node, __context__: context}, _context) do
    case DynamicAgentNode.run(node, context, []) do
      {:ok, result} -> {:ok, %{result: result}}
      {:error, reason} -> {:error, reason}
    end
  end
end
