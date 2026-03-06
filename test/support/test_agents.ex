defmodule Jido.Composer.TestAgents do
  @moduledoc false

  defmodule EchoAgent do
    @moduledoc false
    use Jido.Agent,
      name: "echo_agent",
      description: "Echoes incoming signal data as state",
      schema: [
        result: [type: :any, default: nil]
      ]
  end

  defmodule CounterAgent do
    @moduledoc false
    use Jido.Agent,
      name: "counter_agent",
      description: "Maintains a simple counter",
      schema: [
        count: [type: :integer, default: 0]
      ]
  end

  defmodule TestWorkflowAgent do
    @moduledoc false
    use Jido.Composer.Workflow,
      name: "test_workflow_agent",
      description: "Simple 2-state workflow for nesting tests",
      nodes: %{
        transform: Jido.Composer.TestActions.TransformAction,
        load: Jido.Composer.TestActions.LoadAction
      },
      transitions: %{
        {:transform, :ok} => :load,
        {:load, :ok} => :done,
        {:_, :error} => :failed
      },
      initial: :transform
  end

  defmodule TestOrchestratorAgent do
    @moduledoc false
    use Jido.Composer.Orchestrator,
      name: "test_orchestrator_agent",
      description: "Single-tool orchestrator for nesting tests",
      nodes: [Jido.Composer.TestActions.EchoAction],
      system_prompt: "You have an echo tool. Use it to respond to queries."
  end
end
