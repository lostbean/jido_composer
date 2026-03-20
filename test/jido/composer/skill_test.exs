defmodule Jido.Composer.SkillTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.Skill
  alias Jido.Composer.TestActions.{AddAction, MultiplyAction, EchoAction}
  alias Jido.Composer.TestAgents.TestWorkflowAgent
  alias Jido.Composer.TestSkills

  describe "struct creation" do
    test "creates a Skill with all required fields" do
      skill = %Skill{
        name: "math",
        description: "Math operations",
        prompt_fragment: "Use math tools.",
        tools: [AddAction, MultiplyAction]
      }

      assert skill.name == "math"
      assert skill.description == "Math operations"
      assert skill.prompt_fragment == "Use math tools."
      assert skill.tools == [AddAction, MultiplyAction]
    end

    test "missing name raises ArgumentError" do
      assert_raise ArgumentError, fn ->
        struct!(Skill,
          description: "Math operations",
          prompt_fragment: "Use math tools.",
          tools: [AddAction]
        )
      end
    end

    test "missing description raises ArgumentError" do
      assert_raise ArgumentError, fn ->
        struct!(Skill,
          name: "math",
          prompt_fragment: "Use math tools.",
          tools: [AddAction]
        )
      end
    end

    test "missing prompt_fragment raises ArgumentError" do
      assert_raise ArgumentError, fn ->
        struct!(Skill,
          name: "math",
          description: "Math operations",
          tools: [AddAction]
        )
      end
    end

    test "missing tools raises ArgumentError" do
      assert_raise ArgumentError, fn ->
        struct!(Skill,
          name: "math",
          description: "Math operations",
          prompt_fragment: "Use math tools."
        )
      end
    end
  end

  describe "assemble/2" do
    test "assembles a single skill into a configured agent" do
      skill = TestSkills.math_skill()

      assert {:ok, agent} =
               Skill.assemble([skill],
                 base_prompt: "You are a helper.",
                 model: "anthropic:claude-sonnet-4-20250514"
               )

      assert %Jido.Agent{} = agent

      state = Jido.Agent.Strategy.State.get(agent)
      assert state.system_prompt =~ "You are a helper."
      assert state.system_prompt =~ skill.prompt_fragment

      modules = get_action_modules(agent)
      assert AddAction in modules
      assert MultiplyAction in modules
    end

    test "assembles multiple skills and composes prompts" do
      math = TestSkills.math_skill()
      echo = TestSkills.echo_skill()

      assert {:ok, agent} =
               Skill.assemble([math, echo], model: "anthropic:claude-sonnet-4-20250514")

      state = Jido.Agent.Strategy.State.get(agent)
      assert state.system_prompt =~ math.prompt_fragment
      assert state.system_prompt =~ echo.prompt_fragment

      modules = get_action_modules(agent)
      assert AddAction in modules
      assert MultiplyAction in modules
      assert EchoAction in modules
    end

    test "prompt composition format includes Capabilities header" do
      math = TestSkills.math_skill()
      echo = TestSkills.echo_skill()

      assert {:ok, agent} =
               Skill.assemble([math, echo],
                 base_prompt: "You are a specialist.",
                 model: "anthropic:claude-sonnet-4-20250514"
               )

      state = Jido.Agent.Strategy.State.get(agent)
      prompt = state.system_prompt

      assert prompt =~ "You are a specialist."
      assert prompt =~ "## Capabilities"
      assert prompt =~ math.prompt_fragment
      assert prompt =~ echo.prompt_fragment
    end

    test "prompt with nil base_prompt starts with Capabilities" do
      skill = TestSkills.math_skill()

      assert {:ok, agent} = Skill.assemble([skill], model: "anthropic:claude-sonnet-4-20250514")

      state = Jido.Agent.Strategy.State.get(agent)
      prompt = state.system_prompt

      assert String.starts_with?(prompt, "## Capabilities")
      assert prompt =~ skill.prompt_fragment
    end

    test "deduplicates shared tools" do
      skill1 = %Skill{
        name: "s1",
        description: "First skill",
        prompt_fragment: "Skill 1.",
        tools: [AddAction, EchoAction]
      }

      skill2 = %Skill{
        name: "s2",
        description: "Second skill",
        prompt_fragment: "Skill 2.",
        tools: [AddAction, MultiplyAction]
      }

      assert {:ok, agent} =
               Skill.assemble([skill1, skill2], model: "anthropic:claude-sonnet-4-20250514")

      modules = get_action_modules(agent)
      assert length(Enum.filter(modules, &(&1 == AddAction))) == 1
      assert EchoAction in modules
      assert MultiplyAction in modules
    end

    test "handles agent module as tool" do
      skill = TestSkills.pipeline_skill()

      assert {:ok, agent} = Skill.assemble([skill], model: "anthropic:claude-sonnet-4-20250514")

      modules = get_action_modules(agent)
      assert TestWorkflowAgent in modules
    end

    test "assembles with empty skill list" do
      assert {:ok, agent} =
               Skill.assemble([],
                 base_prompt: "You are a helper.",
                 model: "anthropic:claude-sonnet-4-20250514"
               )

      assert %Jido.Agent{} = agent

      state = Jido.Agent.Strategy.State.get(agent)
      assert state.system_prompt == "You are a helper."

      modules = get_action_modules(agent)
      assert modules == []
    end

    test "assembly options pass through to configure" do
      skill = TestSkills.math_skill()

      assert {:ok, agent} =
               Skill.assemble([skill],
                 model: "anthropic:claude-sonnet-4-20250514",
                 max_iterations: 5,
                 temperature: 0.3
               )

      state = Jido.Agent.Strategy.State.get(agent)
      assert state.max_iterations == 5
      assert state.temperature == 0.3
    end
  end

  # Helper to extract action/agent modules from an assembled agent
  defp get_action_modules(agent) do
    alias Jido.Composer.Node.ActionNode
    alias Jido.Composer.Node.AgentNode

    state = Jido.Agent.Strategy.State.get(agent)

    state
    |> Map.get(:nodes, %{})
    |> Map.values()
    |> Enum.map(fn
      %ActionNode{action_module: mod} -> mod
      %AgentNode{agent_module: mod} -> mod
    end)
  end
end
