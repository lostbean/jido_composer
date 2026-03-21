defmodule Jido.Composer.Orchestrator.ConfigureTest do
  use ExUnit.Case, async: true

  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.Composer.TestActions.{AddAction, EchoAction, MultiplyAction, FinalReportAction}
  alias Jido.Composer.TestSupport.LLMStub

  defmodule ConfigOrchestrator do
    use Jido.Composer.Orchestrator,
      name: "config_orchestrator",
      description: "Orchestrator for configure/2 tests",
      model: "anthropic:claude-sonnet-4-20250514",
      nodes: [
        Jido.Composer.TestActions.AddAction,
        Jido.Composer.TestActions.EchoAction
      ],
      system_prompt: "You are a helpful assistant.",
      temperature: 0.5,
      max_tokens: 2048,
      max_iterations: 5
  end

  defmodule TerminatingConfigOrchestrator do
    use Jido.Composer.Orchestrator,
      name: "terminating_config_orchestrator",
      model: "anthropic:claude-sonnet-4-20250514",
      nodes: [
        Jido.Composer.TestActions.AddAction,
        Jido.Composer.TestActions.EchoAction
      ],
      termination_tool: Jido.Composer.TestActions.FinalReportAction,
      system_prompt: "Call final_report when done."
  end

  describe "configure/2 system_prompt override" do
    test "replaces the system prompt" do
      agent = ConfigOrchestrator.new()
      agent = ConfigOrchestrator.configure(agent, system_prompt: "New prompt")

      state = StratState.get(agent)
      assert state.system_prompt == "New prompt"
    end
  end

  describe "configure/2 model override" do
    test "replaces the model" do
      agent = ConfigOrchestrator.new()
      agent = ConfigOrchestrator.configure(agent, model: "anthropic:claude-opus-4-20250918")

      state = StratState.get(agent)
      assert state.model == "anthropic:claude-opus-4-20250918"
    end
  end

  describe "configure/2 temperature override" do
    test "replaces the temperature" do
      agent = ConfigOrchestrator.new()
      agent = ConfigOrchestrator.configure(agent, temperature: 0.9)

      state = StratState.get(agent)
      assert state.temperature == 0.9
    end
  end

  describe "configure/2 max_tokens override" do
    test "replaces max_tokens" do
      agent = ConfigOrchestrator.new()
      agent = ConfigOrchestrator.configure(agent, max_tokens: 8192)

      state = StratState.get(agent)
      assert state.max_tokens == 8192
    end
  end

  describe "configure/2 req_options override" do
    test "replaces req_options" do
      agent = ConfigOrchestrator.new()
      agent = ConfigOrchestrator.configure(agent, req_options: [plug: {:fake, []}])

      state = StratState.get(agent)
      assert state.req_options == [plug: {:fake, []}]
    end
  end

  describe "configure/2 conversation override" do
    test "sets conversation" do
      agent = ConfigOrchestrator.new()

      conversation =
        ReqLLM.Context.new([
          ReqLLM.Context.user("Hello"),
          ReqLLM.Context.assistant("Hi!")
        ])

      agent = ConfigOrchestrator.configure(agent, conversation: conversation)

      state = StratState.get(agent)
      assert %ReqLLM.Context{} = state.conversation
      assert length(ReqLLM.Context.to_list(state.conversation)) == 2
    end
  end

  describe "configure/2 nodes override" do
    test "rebuilds nodes, tools, and name_atoms from module list" do
      agent = ConfigOrchestrator.new()

      # Replace [AddAction, EchoAction] with just [MultiplyAction]
      agent = ConfigOrchestrator.configure(agent, nodes: [MultiplyAction])

      state = StratState.get(agent)

      # Should have only multiply node
      assert map_size(state.nodes) == 1
      assert Map.has_key?(state.nodes, "multiply")

      # Tools should be rebuilt
      tool_names = Enum.map(state.tools, & &1.name)
      assert "multiply" in tool_names
      refute "add" in tool_names
      refute "echo" in tool_names

      # name_atoms should be rebuilt
      assert Map.has_key?(state.name_atoms, "multiply")
      refute Map.has_key?(state.name_atoms, "add")

      # schema_keys should be rebuilt
      assert Map.has_key?(state.schema_keys, "multiply")
    end

    test "handles termination tool dedup when termination mod is in node list" do
      agent = TerminatingConfigOrchestrator.new()

      # Include FinalReportAction in the nodes list — configure should
      # NOT produce "Tool names must be unique" errors
      agent =
        TerminatingConfigOrchestrator.configure(agent,
          nodes: [AddAction, FinalReportAction]
        )

      state = StratState.get(agent)

      # final_report should appear exactly once in tools
      tool_names = Enum.map(state.tools, & &1.name)
      assert Enum.count(tool_names, &(&1 == "final_report")) == 1
      assert "add" in tool_names

      # Termination tool metadata preserved
      assert state.termination_tool_mod == FinalReportAction
      assert state.termination_tool_name == "final_report"
    end

    test "handles termination tool dedup when termination mod is NOT in node list" do
      agent = TerminatingConfigOrchestrator.new()

      # Exclude FinalReportAction — it should still be added by termination tool logic
      agent = TerminatingConfigOrchestrator.configure(agent, nodes: [AddAction])

      state = StratState.get(agent)

      tool_names = Enum.map(state.tools, & &1.name)
      assert "add" in tool_names
      assert "final_report" in tool_names
      assert state.termination_tool_mod == FinalReportAction
    end
  end

  describe "configure/2 multiple overrides" do
    test "applies multiple overrides at once" do
      agent = ConfigOrchestrator.new()

      agent =
        ConfigOrchestrator.configure(agent,
          system_prompt: "Dynamic prompt",
          model: "anthropic:claude-haiku-4-5-20251001",
          temperature: 0.1,
          max_tokens: 512,
          nodes: [MultiplyAction]
        )

      state = StratState.get(agent)
      assert state.system_prompt == "Dynamic prompt"
      assert state.model == "anthropic:claude-haiku-4-5-20251001"
      assert state.temperature == 0.1
      assert state.max_tokens == 512
      assert map_size(state.nodes) == 1
    end
  end

  describe "configure/2 max_iterations override" do
    test "replaces max_iterations" do
      agent = ConfigOrchestrator.new()
      agent = ConfigOrchestrator.configure(agent, max_iterations: 20)

      state = StratState.get(agent)
      assert state.max_iterations == 20
    end
  end

  describe "configure/2 error handling" do
    test "raises on unknown key" do
      agent = ConfigOrchestrator.new()

      assert_raise ArgumentError, ~r/unknown configure key/, fn ->
        ConfigOrchestrator.configure(agent, bogus: "value")
      end
    end
  end

  describe "get_action_modules/1" do
    test "returns action modules from DSL-declared nodes" do
      agent = ConfigOrchestrator.new()
      modules = ConfigOrchestrator.get_action_modules(agent)

      assert AddAction in modules
      assert EchoAction in modules
    end

    test "reflects nodes override" do
      agent = ConfigOrchestrator.new()
      agent = ConfigOrchestrator.configure(agent, nodes: [MultiplyAction])
      modules = ConfigOrchestrator.get_action_modules(agent)

      assert modules == [MultiplyAction]
    end
  end

  describe "get_termination_module/1" do
    test "returns nil when no termination tool" do
      agent = ConfigOrchestrator.new()
      assert ConfigOrchestrator.get_termination_module(agent) == nil
    end

    test "returns the termination module" do
      agent = TerminatingConfigOrchestrator.new()
      assert TerminatingConfigOrchestrator.get_termination_module(agent) == FinalReportAction
    end
  end

  describe "configure + query_sync integration" do
    test "system_prompt override flows through to LLM call" do
      plug = LLMStub.setup_req_stub(:cfg_prompt, [{:final_answer, "done"}])
      agent = ConfigOrchestrator.new()

      agent =
        ConfigOrchestrator.configure(agent,
          system_prompt: "You are a math tutor.",
          req_options: [plug: plug]
        )

      assert {:ok, _agent, "done"} = ConfigOrchestrator.query_sync(agent, "Help me")
    end

    test "nodes override works with query_sync" do
      plug =
        LLMStub.setup_req_stub(:cfg_nodes, [
          {:tool_calls,
           [%{id: "call_1", name: "multiply", arguments: %{"value" => 3.0, "amount" => 4.0}}]},
          {:final_answer, "3 * 4 = 12"}
        ])

      agent = ConfigOrchestrator.new()

      agent =
        ConfigOrchestrator.configure(agent,
          nodes: [MultiplyAction],
          req_options: [plug: plug]
        )

      assert {:ok, _agent, "3 * 4 = 12"} = ConfigOrchestrator.query_sync(agent, "Multiply 3 by 4")
    end

    test "model override works with query_sync" do
      plug = LLMStub.setup_req_stub(:cfg_model, [{:final_answer, "deep answer"}])
      agent = ConfigOrchestrator.new()

      agent =
        ConfigOrchestrator.configure(agent,
          model: "anthropic:claude-sonnet-4-20250514",
          req_options: [plug: plug]
        )

      assert {:ok, _agent, "deep answer"} = ConfigOrchestrator.query_sync(agent, "Think deeply")
    end

    test "conversation pre-load works with query_sync" do
      plug = LLMStub.setup_req_stub(:cfg_conv, [{:final_answer, "continued"}])
      agent = ConfigOrchestrator.new()

      prior_conversation =
        ReqLLM.Context.new([
          ReqLLM.Context.user("What is 2+2?"),
          ReqLLM.Context.assistant("4")
        ])

      agent =
        ConfigOrchestrator.configure(agent,
          conversation: prior_conversation,
          req_options: [plug: plug]
        )

      assert {:ok, _agent, "continued"} = ConfigOrchestrator.query_sync(agent, "And 3+3?")
    end

    test "read-filter-write pattern for RBAC" do
      plug =
        LLMStub.setup_req_stub(:cfg_rbac, [
          {:tool_calls,
           [%{id: "call_1", name: "add", arguments: %{"value" => 1.0, "amount" => 2.0}}]},
          {:final_answer, "filtered result"}
        ])

      agent = ConfigOrchestrator.new()

      # Read what DSL declared
      all_modules = ConfigOrchestrator.get_action_modules(agent)
      assert AddAction in all_modules
      assert EchoAction in all_modules

      # Filter (simulate RBAC — viewer can't use echo)
      filtered = Enum.filter(all_modules, fn mod -> mod != EchoAction end)

      # Write back
      agent =
        ConfigOrchestrator.configure(agent,
          nodes: filtered,
          req_options: [plug: plug]
        )

      # Verify echo was removed
      state = StratState.get(agent)
      tool_names = Enum.map(state.tools, & &1.name)
      refute "echo" in tool_names
      assert "add" in tool_names

      assert {:ok, _agent, "filtered result"} = ConfigOrchestrator.query_sync(agent, "Add 1+2")
    end
  end
end
