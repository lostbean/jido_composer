defmodule Jido.Composer.Node.DynamicAgentNode.ExecuteAction do
  @moduledoc false
  # Internal action used by DynamicAgentNode.to_directive/3.
  # Retrieves the stashed node + context from process dictionary and
  # delegates to DynamicAgentNode.run/3.

  use Jido.Action,
    name: "dynamic_agent_node_execute",
    description: "Executes a DynamicAgentNode (internal)",
    schema: []

  alias Jido.Composer.Node.DynamicAgentNode

  def run(%{node_ref: ref}, _context) do
    case Process.get({DynamicAgentNode, ref}) do
      {%DynamicAgentNode{} = node, context} ->
        Process.delete({DynamicAgentNode, ref})

        case DynamicAgentNode.run(node, context, []) do
          {:ok, result} -> {:ok, %{result: result}}
          {:error, reason} -> {:error, reason}
        end

      nil ->
        {:error, "DynamicAgentNode reference not found in process dictionary"}
    end
  end
end
