defmodule Jido.Composer.Orchestrator.AgentToolTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.Orchestrator.AgentTool
  alias Jido.Composer.Node.ActionNode
  alias Jido.Composer.Node.DynamicAgentNode
  alias Jido.Composer.NodeIO
  alias Jido.Composer.TestActions.{AddAction, EchoAction}
  alias Jido.Composer.TestSkills

  describe "to_tool/1 with ActionNode" do
    test "returns ReqLLM.Tool struct with name, description, and parameter_schema" do
      {:ok, node} = ActionNode.new(AddAction)
      tool = AgentTool.to_tool(node)

      assert %ReqLLM.Tool{} = tool
      assert tool.name == "add"
      assert tool.description == "Adds an amount to a value"
      assert is_map(tool.parameter_schema) or is_list(tool.parameter_schema)
    end

    test "includes JSON Schema properties from action schema" do
      {:ok, node} = ActionNode.new(AddAction)
      tool = AgentTool.to_tool(node)

      # parameter_schema is a JSON Schema map
      schema = tool.parameter_schema
      assert schema["type"] == "object"
      props = schema["properties"]
      assert Map.has_key?(props, "value")
      assert Map.has_key?(props, "amount")
    end

    test "includes required fields in JSON Schema" do
      {:ok, node} = ActionNode.new(AddAction)
      tool = AgentTool.to_tool(node)

      assert "value" in tool.parameter_schema["required"]
      assert "amount" in tool.parameter_schema["required"]
    end

    test "works with different action modules" do
      {:ok, node} = ActionNode.new(EchoAction)
      tool = AgentTool.to_tool(node)

      assert %ReqLLM.Tool{} = tool
      assert tool.name == "echo"
      assert tool.description == "Echoes input params as the result"
      assert tool.parameter_schema["properties"]["message"]["type"] == "string"
    end
  end

  describe "to_tool/1 with action module directly" do
    test "accepts a raw action module" do
      tool = AgentTool.to_tool(AddAction)

      assert %ReqLLM.Tool{} = tool
      assert tool.name == "add"
      assert tool.description == "Adds an amount to a value"
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

    test "raises for unknown string key without valid_keys" do
      novel_key = "xyzzy_#{System.unique_integer([:positive])}_novel"

      tool_call = %{
        id: "call_novel",
        name: "action",
        arguments: %{novel_key => "value"}
      }

      assert_raise ArgumentError, ~r/unknown tool argument key/, fn ->
        AgentTool.to_context(tool_call)
      end
    end

    test "validates against valid_keys when provided" do
      valid = MapSet.new([:value, :amount])
      tool_call = %{id: "call_1", name: "add", arguments: %{"value" => 1.0, "amount" => 2.0}}
      context = AgentTool.to_context(tool_call, valid)
      assert context[:value] == 1.0
      assert context[:amount] == 2.0
    end

    test "rejects key not in valid_keys" do
      valid = MapSet.new([:value])
      tool_call = %{id: "call_1", name: "add", arguments: %{"value" => 1.0, "amount" => 2.0}}

      assert_raise ArgumentError, ~r/not in schema/, fn ->
        AgentTool.to_context(tool_call, valid)
      end
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

    test "unwraps NodeIO.text for LLM" do
      result =
        AgentTool.to_tool_result("call_text", "research", {:ok, NodeIO.text("Found 5 papers")})

      assert result.id == "call_text"
      assert result.name == "research"
      assert result.result == "Found 5 papers"
      assert is_binary(result.result)
    end

    test "unwraps NodeIO.map for LLM" do
      result = AgentTool.to_tool_result("call_map", "extract", {:ok, NodeIO.map(%{count: 5})})

      assert result.id == "call_map"
      assert result.name == "extract"
      assert result.result == %{count: 5}
      assert is_map(result.result)
    end

    test "unwraps NodeIO.object for LLM" do
      result =
        AgentTool.to_tool_result("call_obj", "analyze", {:ok, NodeIO.object(%{score: 0.9})})

      assert result.id == "call_obj"
      assert result.name == "analyze"
      assert result.result == %{score: 0.9}
    end

    test "handles error tuple with map reason by stringifying" do
      result =
        AgentTool.to_tool_result("call_789", "action", {:error, %{code: 500, msg: "internal"}})

      assert result.id == "call_789"
      assert result.name == "action"
      assert is_binary(result.result.error)
      assert result.result.error =~ "500"
      assert result.result.error =~ "internal"
    end
  end

  describe "to_tool/1 with non-Node struct" do
    test "raises ArgumentError for a struct without to_tool_spec" do
      assert_raise ArgumentError, ~r/does not implement to_tool_spec/, fn ->
        AgentTool.to_tool(%URI{path: "/test"})
      end
    end
  end

  describe "to_tool/1 with DynamicAgentNode" do
    test "returns ReqLLM.Tool struct with name and description" do
      node = %DynamicAgentNode{
        name: "delegate_task",
        description: "Delegates tasks to assembled sub-agents",
        skill_registry: [TestSkills.math_skill()]
      }

      tool = AgentTool.to_tool(node)

      assert %ReqLLM.Tool{} = tool
      assert tool.name == "delegate_task"
      assert tool.description == "Delegates tasks to assembled sub-agents"
    end

    test "parameter_schema includes task and skills properties" do
      node = %DynamicAgentNode{
        name: "delegate",
        description: "Delegate",
        skill_registry: []
      }

      tool = AgentTool.to_tool(node)

      assert tool.parameter_schema["type"] == "object"
      assert tool.parameter_schema["properties"]["task"]["type"] == "string"
      assert tool.parameter_schema["properties"]["skills"]["type"] == "array"
      assert "task" in tool.parameter_schema["required"]
      assert "skills" in tool.parameter_schema["required"]
    end
  end
end
