defmodule Jido.Composer.Orchestrator.AgentTool do
  @moduledoc """
  Converts Nodes into neutral LLM tool descriptions.

  Bridges the gap between Node metadata and the tool format expected by the
  `Jido.Composer.Orchestrator.LLM` behaviour. Three operations handle the
  full round-trip: Node → tool description, tool call → context, and
  execution result → tool result message.
  """

  alias Jido.Composer.Node.ActionNode
  alias Jido.Composer.Node.AgentNode

  @doc """
  Converts a Node or action module into a neutral tool description.

  Returns `%{name, description, parameters}` where parameters is a JSON Schema
  map. Delegates schema conversion to `Jido.Action.Tool.build_parameters_schema/1`.
  """
  @spec to_tool(ActionNode.t() | AgentNode.t() | module()) ::
          Jido.Composer.Orchestrator.LLM.tool()
  def to_tool(%ActionNode{action_module: mod}) do
    to_tool(mod)
  end

  def to_tool(%AgentNode{agent_module: mod}) do
    %{
      name: mod.name(),
      description: mod.description(),
      parameters: build_agent_parameters(mod)
    }
  end

  def to_tool(module) when is_atom(module) do
    %{
      name: module.name(),
      description: module.description(),
      parameters: Jido.Action.Tool.build_parameters_schema(module.schema())
    }
  end

  defp build_agent_parameters(mod) do
    schema = mod.schema()

    if is_list(schema) do
      Jido.Action.Tool.build_parameters_schema(schema)
    else
      # Agent schemas (Zoi) — provide a minimal schema
      %{"type" => "object", "properties" => %{}, "required" => []}
    end
  end

  @doc """
  Converts tool call arguments to a context map for node execution.

  Atomizes string keys so that the resulting map matches the keyword-style
  keys nodes expect.
  """
  @spec to_context(Jido.Composer.Orchestrator.LLM.tool_call()) :: map()
  def to_context(%{arguments: arguments}) do
    Map.new(arguments, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} when is_atom(k) -> {k, v}
    end)
  end

  @doc """
  Builds a normalized tool result from node execution output.

  Returns `%{id, name, result}` matching the `tool_result` type expected by
  `LLM.generate/4`.
  """
  @spec to_tool_result(String.t(), String.t(), {:ok, map()} | {:error, term()}) ::
          Jido.Composer.Orchestrator.LLM.tool_result()
  def to_tool_result(call_id, node_name, {:ok, result}) do
    %{id: call_id, name: node_name, result: result}
  end

  def to_tool_result(call_id, node_name, {:error, reason}) do
    error_message =
      case reason do
        %{message: msg} when is_binary(msg) -> msg
        bin when is_binary(bin) -> bin
        other -> inspect(other)
      end

    %{id: call_id, name: node_name, result: %{error: error_message}}
  end
end
