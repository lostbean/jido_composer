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

  Node structs delegate to their `to_tool_spec/1` callback. Raw action modules
  are handled directly for the termination tool use case.
  """
  @spec to_tool(ActionNode.t() | AgentNode.t() | struct() | module()) :: ReqLLM.Tool.t()
  def to_tool(%mod{} = node) when mod in [ActionNode, AgentNode] do
    spec = mod.to_tool_spec(node)

    ReqLLM.Tool.new!(
      name: spec.name,
      description: spec.description,
      parameter_schema: spec.parameter_schema,
      callback: fn _args -> {:ok, :noop} end
    )
  end

  def to_tool(%mod{} = node) when is_atom(mod) do
    spec = mod.to_tool_spec(node)

    ReqLLM.Tool.new!(
      name: spec.name,
      description: spec.description,
      parameter_schema: spec.parameter_schema,
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

  @doc """
  Converts tool call arguments to a context map for node execution.

  Atomizes string keys so that the resulting map matches the keyword-style
  keys nodes expect. When `valid_keys` is provided, only keys in the set
  are accepted; otherwise falls back to `String.to_existing_atom/1`.
  """
  @spec to_context(map(), MapSet.t(atom()) | nil) :: map()
  def to_context(call, valid_keys \\ nil)

  def to_context(%{arguments: arguments}, valid_keys) do
    Map.new(arguments, fn
      {k, v} when is_binary(k) ->
        key = atomize_key(k, valid_keys)
        {key, v}

      {k, v} when is_atom(k) ->
        {k, v}
    end)
  end

  defp atomize_key(k, nil) do
    try do
      String.to_existing_atom(k)
    rescue
      ArgumentError ->
        raise ArgumentError, "unknown tool argument key #{inspect(k)} — not a recognized atom"
    end
  end

  defp atomize_key(k, valid_keys) do
    atom =
      try do
        String.to_existing_atom(k)
      rescue
        ArgumentError ->
          raise ArgumentError,
                "unknown tool argument key #{inspect(k)} — valid keys: #{inspect(MapSet.to_list(valid_keys))}"
      end

    if MapSet.member?(valid_keys, atom) do
      atom
    else
      raise ArgumentError,
            "tool argument key #{inspect(k)} not in schema — valid keys: #{inspect(MapSet.to_list(valid_keys))}"
    end
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
