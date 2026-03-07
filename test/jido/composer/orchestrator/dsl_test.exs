defmodule Jido.Composer.Orchestrator.DSLTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.TestActions.{AddAction, EchoAction}
  alias Jido.Composer.TestSupport.LLMStub

  defmodule SimpleOrchestrator do
    use Jido.Composer.Orchestrator,
      name: "simple_orchestrator",
      description: "A simple orchestrator for testing",
      model: "anthropic:claude-sonnet-4-20250514",
      nodes: [
        Jido.Composer.TestActions.AddAction,
        Jido.Composer.TestActions.EchoAction
      ],
      system_prompt: "You are a helpful test assistant.",
      max_iterations: 5
  end

  defmodule MinimalOrchestrator do
    use Jido.Composer.Orchestrator,
      name: "minimal_orchestrator",
      model: "anthropic:claude-sonnet-4-20250514",
      nodes: [Jido.Composer.TestActions.AddAction]
  end

  defmodule GatedOrchestrator do
    use Jido.Composer.Orchestrator,
      name: "gated_orchestrator",
      description: "Orchestrator with approval-gated nodes",
      nodes: [
        Jido.Composer.TestActions.AddAction,
        {Jido.Composer.TestActions.EchoAction, requires_approval: true}
      ],
      system_prompt: "You have gated tools."
  end

  describe "module generation" do
    test "generates a module that can create an agent" do
      agent = SimpleOrchestrator.new()
      assert agent.name == "simple_orchestrator"
    end

    test "agent has orchestrator strategy configured" do
      assert SimpleOrchestrator.strategy() == Jido.Composer.Orchestrator.Strategy
    end

    test "strategy_opts contain expected configuration" do
      opts = SimpleOrchestrator.strategy_opts()
      assert is_list(opts[:nodes])
      assert opts[:system_prompt] == "You are a helpful test assistant."
      assert opts[:max_iterations] == 5
    end
  end

  describe "defaults" do
    test "description defaults when not provided" do
      agent = MinimalOrchestrator.new()
      assert agent.name == "minimal_orchestrator"
    end

    test "max_iterations defaults to 10 when not provided" do
      opts = MinimalOrchestrator.strategy_opts()
      assert opts[:max_iterations] == 10
    end

    test "system_prompt defaults to nil when not provided" do
      opts = MinimalOrchestrator.strategy_opts()
      assert opts[:system_prompt] == nil
    end

    test "req_options defaults to empty list" do
      opts = MinimalOrchestrator.strategy_opts()
      assert opts[:req_options] == []
    end

    test "stream defaults to false" do
      opts = MinimalOrchestrator.strategy_opts()
      assert opts[:stream] == false
    end

    test "llm_opts defaults to empty list" do
      opts = MinimalOrchestrator.strategy_opts()
      assert opts[:llm_opts] == []
    end
  end

  describe "node auto-wrapping" do
    test "bare action modules are included in strategy opts nodes list" do
      opts = SimpleOrchestrator.strategy_opts()
      assert AddAction in opts[:nodes]
      assert EchoAction in opts[:nodes]
    end
  end

  describe "signal routes" do
    test "generated module declares orchestrator signal routes" do
      routes = SimpleOrchestrator.signal_routes()
      route_types = Enum.map(routes, fn {type, _target} -> type end)
      assert "composer.orchestrator.query" in route_types
    end
  end

  describe "query/3" do
    test "sends orchestrator_start signal and returns directives" do
      agent = SimpleOrchestrator.new()

      {agent, directives} = SimpleOrchestrator.query(agent, "Hello", %{})

      assert [%Jido.Agent.Directive.RunInstruction{}] = directives
      assert agent.state.__strategy__.status == :awaiting_llm
      assert agent.state.__strategy__.query == "Hello"
    end
  end

  describe "query_sync/3" do
    test "blocks until orchestrator produces final answer" do
      plug = LLMStub.setup_req_stub(:dsl_sync_final, [{:final_answer, "The answer is 42"}])
      agent = SimpleOrchestrator.new()
      # Inject the stub plug into the strategy's req_options
      agent = put_in(agent.state.__strategy__.req_options, plug: plug)

      assert {:ok, "The answer is 42"} = SimpleOrchestrator.query_sync(agent, "What is 42?")
    end

    test "returns error on LLM failure" do
      # Provide multiple error responses to cover Jido.Exec retry attempts
      plug = LLMStub.setup_req_stub(:dsl_sync_error, [{:error, "API down"}, {:error, "API down"}])
      agent = SimpleOrchestrator.new()
      agent = put_in(agent.state.__strategy__.req_options, plug: plug)

      assert {:error, _reason} = SimpleOrchestrator.query_sync(agent, "Fail")
    end
  end

  describe "SpawnAgent directive handling" do
    defmodule OrchestratorWithWorkflowTool do
      use Jido.Composer.Orchestrator,
        name: "orch_with_workflow_tool",
        model: "anthropic:claude-sonnet-4-20250514",
        nodes: [
          Jido.Composer.TestAgents.TestWorkflowAgent,
          Jido.Composer.TestActions.EchoAction
        ],
        system_prompt: "You can run workflows."
    end

    test "query_sync handles SpawnAgent directives for nested agents" do
      plug =
        LLMStub.setup_req_stub(:dsl_orch_spawn, [
          {:tool_calls,
           [
             %{
               id: "call_1",
               name: "test_workflow_agent",
               arguments: %{
                 "source" => "test_db",
                 "extract" => %{"records" => [%{"id" => 1, "source" => "test"}], "count" => 1}
               }
             }
           ]},
          {:final_answer, "Workflow ran successfully."}
        ])

      agent = OrchestratorWithWorkflowTool.new()
      agent = put_in(agent.state.__strategy__.req_options, plug: plug)

      assert {:ok, "Workflow ran successfully."} =
               OrchestratorWithWorkflowTool.query_sync(agent, "Run the workflow")
    end
  end

  describe "node options preservation" do
    defmodule OptionsOrchestrator do
      use Jido.Composer.Orchestrator,
        name: "options_orchestrator",
        nodes: [
          Jido.Composer.TestActions.AddAction,
          {Jido.Composer.TestActions.EchoAction,
           description: "Custom echo", requires_approval: true}
        ]
    end

    test "node options other than requires_approval are preserved" do
      opts = OptionsOrchestrator.strategy_opts()
      # Nodes should carry their extra options for the strategy to use
      nodes = opts[:nodes]

      echo_entry =
        Enum.find(nodes, fn
          {mod, _opts} when is_atom(mod) -> mod == Jido.Composer.TestActions.EchoAction
          mod when is_atom(mod) -> mod == Jido.Composer.TestActions.EchoAction
          _ -> false
        end)

      assert echo_entry != nil
      # Options like description should be preserved as a tuple
      assert {Jido.Composer.TestActions.EchoAction, opts_list} = echo_entry
      assert Keyword.get(opts_list, :description) == "Custom echo"
    end
  end

  describe "HITL DSL options" do
    defmodule HITLOrchestrator do
      use Jido.Composer.Orchestrator,
        name: "hitl_orchestrator",
        nodes: [
          {Jido.Composer.TestActions.AddAction, requires_approval: true}
        ],
        rejection_policy: :cancel_siblings
    end

    test "rejection_policy is passed to strategy opts" do
      opts = HITLOrchestrator.strategy_opts()
      assert opts[:rejection_policy] == :cancel_siblings
    end
  end

  describe "gated_nodes via DSL" do
    test "requires_approval metadata is passed through to strategy opts" do
      opts = GatedOrchestrator.strategy_opts()
      assert is_list(opts[:gated_nodes])
      assert "echo" in opts[:gated_nodes]
    end

    test "non-gated nodes are not in gated_nodes list" do
      opts = GatedOrchestrator.strategy_opts()
      refute "add" in opts[:gated_nodes]
    end
  end

  describe "LLM generation options in DSL" do
    defmodule CustomLLMOrchestrator do
      use Jido.Composer.Orchestrator,
        name: "custom_llm_orchestrator",
        model: "anthropic:claude-sonnet-4-20250514",
        nodes: [Jido.Composer.TestActions.AddAction],
        temperature: 0.2,
        max_tokens: 4096,
        stream: false,
        llm_opts: [top_p: 0.95]
    end

    test "temperature is passed to strategy opts" do
      opts = CustomLLMOrchestrator.strategy_opts()
      assert opts[:temperature] == 0.2
    end

    test "max_tokens is passed to strategy opts" do
      opts = CustomLLMOrchestrator.strategy_opts()
      assert opts[:max_tokens] == 4096
    end

    test "stream is passed to strategy opts" do
      opts = CustomLLMOrchestrator.strategy_opts()
      assert opts[:stream] == false
    end

    test "llm_opts are passed to strategy opts" do
      opts = CustomLLMOrchestrator.strategy_opts()
      assert opts[:llm_opts] == [top_p: 0.95]
    end
  end
end
