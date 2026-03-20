defmodule Jido.Composer.TestSkills do
  @moduledoc false

  alias Jido.Composer.Skill
  alias Jido.Composer.TestActions.{AddAction, MultiplyAction, EchoAction}
  alias Jido.Composer.TestAgents.TestWorkflowAgent

  def math_skill do
    %Skill{
      name: "math",
      description: "Perform arithmetic operations like addition and multiplication",
      prompt_fragment: "You can perform math operations using the add and multiply tools.",
      tools: [AddAction, MultiplyAction]
    }
  end

  def echo_skill do
    %Skill{
      name: "echo",
      description: "Echo messages back to the user",
      prompt_fragment: "You can echo messages using the echo tool.",
      tools: [EchoAction]
    }
  end

  def pipeline_skill do
    %Skill{
      name: "pipeline",
      description: "Run data transformation pipelines",
      prompt_fragment: "You can run data pipelines using the test_workflow_agent tool.",
      tools: [TestWorkflowAgent]
    }
  end
end
