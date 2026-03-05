defmodule Jido.Composer.Orchestrator.AgentToolTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.Orchestrator.AgentTool
  alias Jido.Composer.Node.ActionNode
  alias Jido.Composer.TestActions.{AddAction, EchoAction}

  describe "to_tool/1 with ActionNode" do
    test "returns neutral tool description with name, description, and parameters" do
      {:ok, node} = ActionNode.new(AddAction)
      tool = AgentTool.to_tool(node)

      assert tool.name == "add"
      assert tool.description == "Adds an amount to a value"
      assert is_map(tool.parameters)
      assert tool.parameters["type"] == "object"
      assert is_map(tool.parameters["properties"])
    end

    test "includes JSON Schema properties from action schema" do
      {:ok, node} = ActionNode.new(AddAction)
      tool = AgentTool.to_tool(node)

      props = tool.parameters["properties"]
      assert Map.has_key?(props, "value")
      assert Map.has_key?(props, "amount")
    end

    test "includes required fields in JSON Schema" do
      {:ok, node} = ActionNode.new(AddAction)
      tool = AgentTool.to_tool(node)

      assert "value" in tool.parameters["required"]
      assert "amount" in tool.parameters["required"]
    end

    test "works with different action modules" do
      {:ok, node} = ActionNode.new(EchoAction)
      tool = AgentTool.to_tool(node)

      assert tool.name == "echo"
      assert tool.description == "Echoes input params as the result"
      assert tool.parameters["properties"]["message"]["type"] == "string"
    end
  end

  describe "to_tool/1 with action module directly" do
    test "accepts a raw action module" do
      tool = AgentTool.to_tool(AddAction)

      assert tool.name == "add"
      assert tool.description == "Adds an amount to a value"
      assert is_map(tool.parameters)
    end
  end

  describe "to_context/1" do
    test "converts tool call arguments to context map with atom keys" do
      tool_call = %{id: "call_123", name: "add", arguments: %{"value" => 10.0, "amount" => 5.0}}
      context = AgentTool.to_context(tool_call)

      assert context[:value] == 10.0
      assert context[:amount] == 5.0
    end

    test "passes through atom-keyed arguments unchanged" do
      tool_call = %{id: "call_456", name: "echo", arguments: %{message: "hello"}}
      context = AgentTool.to_context(tool_call)

      assert context[:message] == "hello"
    end

    test "handles empty arguments" do
      tool_call = %{id: "call_789", name: "noop", arguments: %{}}
      context = AgentTool.to_context(tool_call)

      assert context == %{}
    end
  end

  describe "to_tool_result/3" do
    test "wraps successful result as tool result" do
      result = AgentTool.to_tool_result("call_123", "add", {:ok, %{result: 15.0}})

      assert result.id == "call_123"
      assert result.name == "add"
      assert result.result == %{result: 15.0}
    end

    test "wraps error result with error key" do
      result = AgentTool.to_tool_result("call_456", "fail", {:error, "something broke"})

      assert result.id == "call_456"
      assert result.name == "fail"
      assert result.result == %{error: "something broke"}
    end

    test "handles error tuple with map reason" do
      result =
        AgentTool.to_tool_result("call_789", "action", {:error, %{code: 500, msg: "internal"}})

      assert result.id == "call_789"
      assert result.name == "action"
      assert result.result == %{error: %{code: 500, msg: "internal"}}
    end
  end
end
