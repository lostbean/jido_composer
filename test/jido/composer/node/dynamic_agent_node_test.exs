defmodule Jido.Composer.Node.DynamicAgentNodeTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.Node.DynamicAgentNode
  alias Jido.Composer.TestSkills
  alias Jido.Composer.TestSupport.LLMStub

  describe "struct creation" do
    test "creates a DynamicAgentNode with required fields" do
      node = %DynamicAgentNode{
        name: "delegate_task",
        description: "Delegates tasks to assembled sub-agents",
        skill_registry: [TestSkills.math_skill()]
      }

      assert node.name == "delegate_task"
      assert node.description == "Delegates tasks to assembled sub-agents"
      assert length(node.skill_registry) == 1
      assert node.assembly_opts == []
    end

    test "accepts assembly_opts" do
      node = %DynamicAgentNode{
        name: "delegate",
        description: "Delegate",
        skill_registry: [],
        assembly_opts: [model: "anthropic:claude-sonnet-4-20250514", max_iterations: 5]
      }

      assert node.assembly_opts == [
               model: "anthropic:claude-sonnet-4-20250514",
               max_iterations: 5
             ]
    end

    test "missing name raises ArgumentError" do
      assert_raise ArgumentError, fn ->
        struct!(DynamicAgentNode,
          description: "Delegate",
          skill_registry: []
        )
      end
    end

    test "missing description raises ArgumentError" do
      assert_raise ArgumentError, fn ->
        struct!(DynamicAgentNode,
          name: "delegate",
          skill_registry: []
        )
      end
    end

    test "missing skill_registry raises ArgumentError" do
      assert_raise ArgumentError, fn ->
        struct!(DynamicAgentNode,
          name: "delegate",
          description: "Delegate"
        )
      end
    end
  end

  describe "name/1" do
    test "returns the configured name" do
      node = %DynamicAgentNode{
        name: "delegate_task",
        description: "Delegate",
        skill_registry: []
      }

      assert DynamicAgentNode.name(node) == "delegate_task"
    end
  end

  describe "description/1" do
    test "returns the configured description" do
      node = %DynamicAgentNode{
        name: "delegate",
        description: "Delegates tasks to assembled sub-agents",
        skill_registry: []
      }

      assert DynamicAgentNode.description(node) == "Delegates tasks to assembled sub-agents"
    end
  end

  describe "schema/1" do
    test "returns schema with task and skills fields" do
      node = %DynamicAgentNode{
        name: "delegate",
        description: "Delegate",
        skill_registry: []
      }

      schema = DynamicAgentNode.schema(node)
      assert is_list(schema)

      keys = Keyword.keys(schema)
      assert :task in keys
      assert :skills in keys
    end
  end

  describe "to_tool_spec/1" do
    test "returns tool spec with correct structure" do
      node = %DynamicAgentNode{
        name: "delegate_task",
        description: "Delegates tasks to assembled sub-agents",
        skill_registry: [TestSkills.math_skill()]
      }

      spec = DynamicAgentNode.to_tool_spec(node)

      assert spec.name == "delegate_task"
      assert spec.description == "Delegates tasks to assembled sub-agents"
      assert is_map(spec.parameter_schema)
    end

    test "parameter_schema includes task property of type string" do
      node = %DynamicAgentNode{
        name: "delegate",
        description: "Delegate",
        skill_registry: []
      }

      spec = DynamicAgentNode.to_tool_spec(node)
      props = spec.parameter_schema["properties"]

      assert props["task"]["type"] == "string"
    end

    test "parameter_schema includes skills property of type array with string items" do
      node = %DynamicAgentNode{
        name: "delegate",
        description: "Delegate",
        skill_registry: []
      }

      spec = DynamicAgentNode.to_tool_spec(node)
      props = spec.parameter_schema["properties"]

      assert props["skills"]["type"] == "array"
      assert props["skills"]["items"]["type"] == "string"
    end

    test "parameter_schema marks both fields as required" do
      node = %DynamicAgentNode{
        name: "delegate",
        description: "Delegate",
        skill_registry: []
      }

      spec = DynamicAgentNode.to_tool_spec(node)

      assert "task" in spec.parameter_schema["required"]
      assert "skills" in spec.parameter_schema["required"]
    end
  end

  describe "Node behaviour" do
    test "DynamicAgentNode declares Node behaviour" do
      behaviours =
        DynamicAgentNode.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Jido.Composer.Node in behaviours
    end
  end

  describe "run/3" do
    test "successful run with action-only skills" do
      # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
      stub_name = :"dynamic_run_action_#{System.unique_integer([:positive])}"

      plug =
        LLMStub.setup_req_stub(stub_name, [
          {:tool_calls,
           [
             %{
               id: "call_1",
               name: "add",
               arguments: %{"value" => 1.0, "amount" => 2.0}
             }
           ]},
          {:final_answer, "The result is 3.0"}
        ])

      node = %DynamicAgentNode{
        name: "delegate",
        description: "Delegate",
        skill_registry: [TestSkills.math_skill()],
        assembly_opts: [
          model: "anthropic:claude-sonnet-4-20250514",
          req_options: [plug: plug]
        ]
      }

      context = %{task: "Add 1 and 2", skills: ["math"]}
      assert {:ok, result} = DynamicAgentNode.run(node, context, [])
      assert is_binary(result) or is_map(result)
    end

    test "unknown skill name returns error" do
      node = %DynamicAgentNode{
        name: "delegate",
        description: "Delegate",
        skill_registry: [TestSkills.math_skill()]
      }

      context = %{task: "Do something", skills: ["nonexistent"]}
      assert {:error, reason} = DynamicAgentNode.run(node, context, [])
      assert reason =~ "nonexistent"
    end

    test "multiple skills combine tools" do
      # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
      stub_name = :"dynamic_run_multi_#{System.unique_integer([:positive])}"

      plug =
        LLMStub.setup_req_stub(stub_name, [
          {:tool_calls,
           [
             %{
               id: "call_1",
               name: "add",
               arguments: %{"value" => 1.0, "amount" => 2.0}
             }
           ]},
          {:tool_calls,
           [
             %{
               id: "call_2",
               name: "echo",
               arguments: %{"message" => "hello"}
             }
           ]},
          {:final_answer, "Done: 3.0 and echoed hello"}
        ])

      node = %DynamicAgentNode{
        name: "delegate",
        description: "Delegate",
        skill_registry: [TestSkills.math_skill(), TestSkills.echo_skill()],
        assembly_opts: [
          model: "anthropic:claude-sonnet-4-20250514",
          req_options: [plug: plug]
        ]
      }

      context = %{task: "Add 1+2 then echo hello", skills: ["math", "echo"]}
      assert {:ok, result} = DynamicAgentNode.run(node, context, [])
      assert is_binary(result) or is_map(result)
    end
  end
end
