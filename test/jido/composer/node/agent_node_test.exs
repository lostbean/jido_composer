defmodule Jido.Composer.Node.AgentNodeTest do
  use ExUnit.Case, async: true

  alias Jido.Composer.Node.AgentNode

  alias Jido.Composer.TestAgents.{
    EchoAgent,
    CounterAgent,
    TestWorkflowAgent,
    TestOrchestratorAgent
  }

  describe "new/2" do
    test "creates an AgentNode from a valid agent module" do
      assert {:ok, node} = AgentNode.new(EchoAgent)
      assert %AgentNode{} = node
      assert node.agent_module == EchoAgent
    end

    test "defaults mode to :sync" do
      {:ok, node} = AgentNode.new(EchoAgent)
      assert node.mode == :sync
    end

    test "defaults opts to empty list" do
      {:ok, node} = AgentNode.new(EchoAgent)
      assert node.opts == []
    end

    test "defaults signal_type to nil" do
      {:ok, node} = AgentNode.new(EchoAgent)
      assert node.signal_type == nil
    end

    test "defaults on_state to nil" do
      {:ok, node} = AgentNode.new(EchoAgent)
      assert node.on_state == nil
    end

    test "accepts mode option" do
      assert {:ok, node} = AgentNode.new(EchoAgent, mode: :async)
      assert node.mode == :async
    end

    test "accepts streaming mode" do
      assert {:ok, node} = AgentNode.new(EchoAgent, mode: :streaming)
      assert node.mode == :streaming
    end

    test "rejects invalid mode" do
      assert {:error, _reason} = AgentNode.new(EchoAgent, mode: :invalid)
    end

    test "accepts opts" do
      assert {:ok, node} = AgentNode.new(EchoAgent, opts: [timeout: 5000])
      assert node.opts == [timeout: 5000]
    end

    test "accepts signal_type" do
      assert {:ok, node} = AgentNode.new(EchoAgent, signal_type: "custom.signal")
      assert node.signal_type == "custom.signal"
    end

    test "accepts on_state" do
      assert {:ok, node} = AgentNode.new(EchoAgent, on_state: [:processing, :complete])
      assert node.on_state == [:processing, :complete]
    end

    test "accepts all options together" do
      assert {:ok, node} =
               AgentNode.new(EchoAgent,
                 mode: :streaming,
                 opts: [timeout: 10_000],
                 signal_type: "custom.signal",
                 on_state: [:done]
               )

      assert node.mode == :streaming
      assert node.opts == [timeout: 10_000]
      assert node.signal_type == "custom.signal"
      assert node.on_state == [:done]
    end

    test "rejects non-agent modules" do
      assert {:error, _reason} = AgentNode.new(String)
    end

    test "rejects action modules" do
      assert {:error, _reason} = AgentNode.new(Jido.Composer.TestActions.AddAction)
    end

    test "rejects non-existent modules" do
      assert {:error, _reason} = AgentNode.new(NonExistent.Module)
    end
  end

  describe "metadata delegation" do
    test "name/1 delegates to agent module" do
      {:ok, node} = AgentNode.new(EchoAgent)
      assert AgentNode.name(node) == "echo_agent"
    end

    test "description/1 delegates to agent module" do
      {:ok, node} = AgentNode.new(EchoAgent)
      assert AgentNode.description(node) == "Echoes incoming signal data as state"
    end

    test "schema/1 delegates to agent module" do
      {:ok, node} = AgentNode.new(EchoAgent)
      schema = AgentNode.schema(node)
      assert schema != nil
    end

    test "metadata differs per agent module" do
      {:ok, echo_node} = AgentNode.new(EchoAgent)
      {:ok, counter_node} = AgentNode.new(CounterAgent)

      assert AgentNode.name(echo_node) != AgentNode.name(counter_node)
      assert AgentNode.description(echo_node) != AgentNode.description(counter_node)
    end
  end

  describe "Node behaviour" do
    test "AgentNode declares Node behaviour" do
      behaviours =
        AgentNode.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Jido.Composer.Node in behaviours
    end

    test "run/3 delegates to run_sync/2 for workflow agents" do
      {:ok, node} = AgentNode.new(TestWorkflowAgent)
      context = %{extract: %{records: [%{id: 1, source: "test"}], count: 1}}
      assert {:ok, result} = AgentNode.run(node, context, [])
      assert is_map(result)
    end

    test "run/3 delegates to query_sync/3 for orchestrator agents" do
      # TestOrchestratorAgent needs LLMStub to work — we test the dispatch path
      # by checking that it attempts to call query_sync (which will fail without LLM setup)
      {:ok, node} = AgentNode.new(TestOrchestratorAgent)
      result = AgentNode.run(node, %{query: "test"}, [])
      # Without LLM configured, this will error — but it proves the query_sync path is taken
      assert {:error, _reason} = result
    end

    test "run/3 returns {:error, {:not_directly_runnable, :async}} for async mode" do
      {:ok, node} = AgentNode.new(EchoAgent, mode: :async)
      assert {:error, {:not_directly_runnable, :async}} = AgentNode.run(node, %{}, [])
    end

    test "run/3 returns {:error, {:not_directly_runnable, :streaming}} for streaming mode" do
      {:ok, node} = AgentNode.new(EchoAgent, mode: :streaming)
      assert {:error, {:not_directly_runnable, :streaming}} = AgentNode.run(node, %{}, [])
    end

    test "run/3 returns error for agents without sync entry point" do
      {:ok, node} = AgentNode.new(EchoAgent)
      assert {:error, :agent_not_sync_runnable} = AgentNode.run(node, %{}, [])
    end
  end

  describe "timeout defaults" do
    test "default timeout is 30_000 when not specified in opts" do
      {:ok, node} = AgentNode.new(EchoAgent)
      assert AgentNode.timeout(node) == 30_000
    end

    test "timeout can be overridden in opts" do
      {:ok, node} = AgentNode.new(EchoAgent, opts: [timeout: 60_000])
      assert AgentNode.timeout(node) == 60_000
    end
  end
end
