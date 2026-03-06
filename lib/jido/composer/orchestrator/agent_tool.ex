defmodule Jido.Composer.Orchestrator.AgentTool do
  @moduledoc """
  Converts Nodes into ReqLLM Tool structs for LLM function calling.

  Bridges the gap between Node metadata and `ReqLLM.Tool` structs.
  Three operations handle the full round-trip: Node → tool description,
  tool call → context, and execution result → tool result message.
  """

  alias Jido.Composer.Node.ActionNode
  alias Jido.Composer.Node.AgentNode
  alias Jido.Composer.NodeIO

  @doc """
  Converts a Node or action module into a `ReqLLM.Tool` struct.

  Returns `%ReqLLM.Tool{}` with name, description, parameter_schema (JSON Schema map),
  and a no-op callback (the orchestrator executes tools externally).
  """
  @spec to_tool(ActionNode.t() | AgentNode.t() | module()) :: ReqLLM.Tool.t()
  def to_tool(%ActionNode{action_module: mod}) do
    to_tool(mod)
  end

  def to_tool(%AgentNode{agent_module: mod}) do
    ReqLLM.Tool.new!(
      name: mod.name(),
      description: mod.description(),
      parameter_schema: build_agent_parameters(mod),
      callback: fn _args -> {:ok, :noop} end
    )
  end

  def to_tool(module) when is_atom(module) do
    ReqLLM.Tool.new!(
      name: module.name(),
      description: module.description(),
      parameter_schema: Jido.Action.Tool.build_parameters_schema(module.schema()),
      callback: fn _args -> {:ok, :noop} end
    )
  end

  defp build_agent_parameters(mod) do
    schema = mod.schema()

    if is_list(schema) do
      Jido.Action.Tool.build_parameters_schema(schema)
    else
      %{"type" => "object", "properties" => %{}, "required" => []}
    end
  end

  @doc """
  Converts tool call arguments to a context map for node execution.

  Atomizes string keys so that the resulting map matches the keyword-style
  keys nodes expect.
  """
  @spec to_context(map()) :: map()
  def to_context(%{arguments: arguments}) do
    Map.new(arguments, fn
      {k, v} when is_binary(k) ->
        # Tool call keys are bounded by tool schemas (from Node definitions),
        # not arbitrary user input. Try existing atom first; fall back for
        # schema-defined keys not yet loaded as atoms in the VM.
        key =
          try do
            String.to_existing_atom(k)
          rescue
            # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
            ArgumentError -> String.to_atom(k)
          end

        {key, v}

      {k, v} when is_atom(k) ->
        {k, v}
    end)
  end

  @doc """
  Builds a normalized tool result from node execution output.

  Returns `%{id, name, result}` for feeding back into the LLM conversation.
  """
  @spec to_tool_result(String.t(), String.t(), {:ok, map() | NodeIO.t()} | {:error, term()}) ::
          map()
  def to_tool_result(call_id, node_name, {:ok, %NodeIO{type: :text, value: text}}) do
    %{id: call_id, name: node_name, result: text}
  end

  def to_tool_result(call_id, node_name, {:ok, %NodeIO{} = io}) do
    %{id: call_id, name: node_name, result: NodeIO.unwrap(io)}
  end

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
