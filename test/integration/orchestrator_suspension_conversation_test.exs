defmodule Jido.Composer.Integration.OrchestratorSuspensionConversationTest do
  @moduledoc """
  Tests for the refactored suspension conversation model.

  Key invariants:
  1. Conversation stores only REAL tool_results — no synthetics at suspension time
  2. Orphaned pending tool IDs are cleaned up by the DSL on suspend
  3. Orphaned tool_use entries are stripped from assistant messages at LLM-call time
  4. Resume produces exactly one tool_result per tool_use_id — no duplicates
  """
  use ExUnit.Case, async: true

  alias Jido.Composer.TestSupport.LLMStub

  # -- Test orchestrator module --

  defmodule SuspendOrchestrator do
    use Jido.Composer.Orchestrator,
      name: "suspend_conv_orchestrator",
      model: "anthropic:claude-sonnet-4-20250514",
      nodes: [
        Jido.Composer.TestActions.AddAction,
        Jido.Composer.TestActions.EchoAction,
        Jido.Composer.TestActions.SuspendAction
      ],
      system_prompt: "You are a test assistant with add, echo, and suspend tools."
  end

  # -- Helpers --

  defp find_tool_results(%ReqLLM.Context{messages: messages}, tool_call_id) do
    Enum.filter(messages, fn msg ->
      msg.role == :tool and msg.tool_call_id == tool_call_id
    end)
  end

  defp count_tool_results(%ReqLLM.Context{messages: messages}, tool_call_id) do
    Enum.count(messages, fn msg ->
      msg.role == :tool and msg.tool_call_id == tool_call_id
    end)
  end

  defp all_tool_result_ids(%ReqLLM.Context{messages: messages}) do
    messages
    |> Enum.filter(&(&1.role == :tool))
    |> Enum.map(& &1.tool_call_id)
    |> Enum.reject(&is_nil/1)
  end

  # -- Tests --

  describe "single tool suspension — no synthetic in conversation" do
    test "conversation has NO tool_result for suspended call" do
      plug =
        LLMStub.setup_req_stub(:single_suspend, [
          {:tool_calls,
           [%{id: "call_suspend_1", name: "suspend", arguments: %{"checkpoint" => "waiting"}}]}
        ])

      agent = SuspendOrchestrator.new()
      agent = put_in(agent.state.__strategy__.req_options, plug: plug)

      assert {:suspended, returned_agent, %Jido.Composer.Suspension{}} =
               SuspendOrchestrator.query_sync(agent, "Please suspend")

      strat = returned_agent.state.__strategy__
      assert %ReqLLM.Context{} = strat.conversation

      # No tool_result in conversation for the suspended call
      assert find_tool_results(strat.conversation, "call_suspend_1") == []

      # Pending should be clean
      assert strat.tool_concurrency.pending == []
    end
  end

  describe "multi-tool (add completes, suspend fires)" do
    test "completed result stays in tool_concurrency, not conversation" do
      plug =
        LLMStub.setup_req_stub(:multi_tool_suspend, [
          {:tool_calls,
           [
             %{id: "call_add_1", name: "add", arguments: %{"value" => 5.0, "amount" => 3.0}},
             %{id: "call_suspend_1", name: "suspend", arguments: %{"checkpoint" => "waiting"}}
           ]}
        ])

      agent = SuspendOrchestrator.new()
      agent = put_in(agent.state.__strategy__.req_options, plug: plug)

      assert {:suspended, returned_agent, _suspension} =
               SuspendOrchestrator.query_sync(agent, "Add and then suspend")

      strat = returned_agent.state.__strategy__
      assert %ReqLLM.Context{} = strat.conversation

      # No tool_result in conversation for either call
      assert find_tool_results(strat.conversation, "call_add_1") == []
      assert find_tool_results(strat.conversation, "call_suspend_1") == []

      # Completed result is in tool_concurrency
      assert Enum.any?(strat.tool_concurrency.completed, &(&1.id == "call_add_1"))

      # Pending is clean
      assert strat.tool_concurrency.pending == []
    end
  end

  describe "suspend first, sibling never dispatched" do
    test "orphaned pending cleaned, no synthetics in conversation" do
      plug =
        LLMStub.setup_req_stub(:early_suspend, [
          {:tool_calls,
           [
             %{id: "call_suspend_1", name: "suspend", arguments: %{"checkpoint" => "waiting"}},
             %{id: "call_add_1", name: "add", arguments: %{"value" => 5.0, "amount" => 3.0}}
           ]}
        ])

      agent = SuspendOrchestrator.new()
      agent = put_in(agent.state.__strategy__.req_options, plug: plug)

      assert {:suspended, returned_agent, _suspension} =
               SuspendOrchestrator.query_sync(agent, "Suspend and add")

      strat = returned_agent.state.__strategy__
      assert %ReqLLM.Context{} = strat.conversation

      # No tool_results in conversation
      assert all_tool_result_ids(strat.conversation) == []

      # Orphaned add should NOT be in pending
      refute "call_add_1" in strat.tool_concurrency.pending
    end
  end

  describe "three tools, middle suspends" do
    test "echo result in completed, add orphaned cleaned, no tool_results in conversation" do
      plug =
        LLMStub.setup_req_stub(:three_tool_suspend, [
          {:tool_calls,
           [
             %{id: "call_echo_1", name: "echo", arguments: %{"message" => "hello"}},
             %{id: "call_suspend_1", name: "suspend", arguments: %{"checkpoint" => "mid"}},
             %{id: "call_add_1", name: "add", arguments: %{"value" => 1.0, "amount" => 2.0}}
           ]}
        ])

      agent = SuspendOrchestrator.new()
      agent = put_in(agent.state.__strategy__.req_options, plug: plug)

      assert {:suspended, returned_agent, _suspension} =
               SuspendOrchestrator.query_sync(agent, "Echo, suspend, add")

      strat = returned_agent.state.__strategy__
      assert %ReqLLM.Context{} = strat.conversation

      # No tool_results in conversation at suspension time
      assert all_tool_result_ids(strat.conversation) == []

      # Echo's real result is in tool_concurrency.completed
      assert Enum.any?(strat.tool_concurrency.completed, &(&1.id == "call_echo_1"))

      # Orphaned add is NOT in pending
      refute "call_add_1" in strat.tool_concurrency.pending
    end
  end

  describe "no duplicate tool_results after resume" do
    test "suspended call has exactly ONE tool_result in final conversation" do
      plug =
        LLMStub.setup_req_stub(:resume_no_dup, [
          # LLM call 1: suspend
          {:tool_calls,
           [%{id: "call_suspend_1", name: "suspend", arguments: %{"checkpoint" => "waiting"}}]},
          # LLM call 2: final answer after resume
          {:final_answer, "done"}
        ])

      agent = SuspendOrchestrator.new()
      agent = put_in(agent.state.__strategy__.req_options, plug: plug)

      # First query → suspended
      assert {:suspended, agent, suspension} =
               SuspendOrchestrator.query_sync(agent, "Please suspend")

      # Resume
      {agent, directives} =
        SuspendOrchestrator.cmd(
          agent,
          {:suspend_resume,
           %{
             suspension_id: suspension.id,
             data: %{approved: true}
           }}
        )

      # Process directives to completion
      assert {:ok, final_agent, "done"} =
               Jido.Composer.Orchestrator.DSL.__query_sync_loop__(
                 SuspendOrchestrator,
                 agent,
                 directives
               )

      strat = final_agent.state.__strategy__

      # Exactly ONE tool_result for the suspended call
      assert count_tool_results(strat.conversation, "call_suspend_1") == 1

      # Assistant message's tool_calls should only contain suspend (no orphans)
      assistant_msgs =
        Enum.filter(strat.conversation.messages, &(&1.role == :assistant))

      assert Enum.any?(assistant_msgs, fn msg ->
               is_list(msg.tool_calls) and
                 Enum.any?(msg.tool_calls, &(&1.id == "call_suspend_1"))
             end)
    end
  end

  describe "orphaned tool_use is stripped from assistant message after resume" do
    test "orphaned tool_use removed, only real results remain" do
      plug =
        LLMStub.setup_req_stub(:orphan_strip, [
          # LLM call 1: echo + suspend + add
          {:tool_calls,
           [
             %{id: "call_echo_1", name: "echo", arguments: %{"message" => "hi"}},
             %{id: "call_suspend_1", name: "suspend", arguments: %{"checkpoint" => "mid"}},
             %{id: "call_add_1", name: "add", arguments: %{"value" => 1.0, "amount" => 2.0}}
           ]},
          # LLM call 2: final answer after resume
          {:final_answer, "done"}
        ])

      agent = SuspendOrchestrator.new()
      agent = put_in(agent.state.__strategy__.req_options, plug: plug)

      # First query → suspended
      assert {:suspended, agent, suspension} =
               SuspendOrchestrator.query_sync(agent, "Echo, suspend, add")

      # Resume
      {agent, directives} =
        SuspendOrchestrator.cmd(
          agent,
          {:suspend_resume,
           %{
             suspension_id: suspension.id,
             data: %{approved: true}
           }}
        )

      # Process directives to completion
      assert {:ok, final_agent, "done"} =
               Jido.Composer.Orchestrator.DSL.__query_sync_loop__(
                 SuspendOrchestrator,
                 agent,
                 directives
               )

      strat = final_agent.state.__strategy__

      # Only real tool_results for echo and suspend
      assert count_tool_results(strat.conversation, "call_echo_1") == 1
      assert count_tool_results(strat.conversation, "call_suspend_1") == 1

      # NO tool_result for the orphaned add
      assert count_tool_results(strat.conversation, "call_add_1") == 0

      # Assistant message's tool_calls should only have echo and suspend (add stripped)
      assistant_msgs =
        Enum.filter(strat.conversation.messages, &(&1.role == :assistant))

      all_tool_call_ids =
        assistant_msgs
        |> Enum.flat_map(fn msg -> msg.tool_calls || [] end)
        |> Enum.map(& &1.id)

      assert "call_echo_1" in all_tool_call_ids
      assert "call_suspend_1" in all_tool_call_ids
      refute "call_add_1" in all_tool_call_ids
    end
  end

  describe "stripped conversation is valid for consumer persistence round-trip" do
    test "no synthetics survive suspend → resume → complete cycle" do
      plug =
        LLMStub.setup_req_stub(:persistence_roundtrip, [
          # LLM call 1: suspend + add (add will be orphaned)
          {:tool_calls,
           [
             %{id: "call_suspend_1", name: "suspend", arguments: %{"checkpoint" => "waiting"}},
             %{id: "call_add_1", name: "add", arguments: %{"value" => 1.0, "amount" => 2.0}}
           ]},
          # LLM call 2: final answer after resume
          {:final_answer, "done"}
        ])

      agent = SuspendOrchestrator.new()
      agent = put_in(agent.state.__strategy__.req_options, plug: plug)

      # First query → suspended
      assert {:suspended, agent, suspension} =
               SuspendOrchestrator.query_sync(agent, "Suspend and add")

      # Suspension-time invariant: no tool_results in conversation
      suspended_strat = agent.state.__strategy__
      assert all_tool_result_ids(suspended_strat.conversation) == []

      # Resume
      {agent, directives} =
        SuspendOrchestrator.cmd(
          agent,
          {:suspend_resume,
           %{
             suspension_id: suspension.id,
             data: %{approved: true}
           }}
        )

      # Process directives to completion
      assert {:ok, final_agent, "done"} =
               Jido.Composer.Orchestrator.DSL.__query_sync_loop__(
                 SuspendOrchestrator,
                 agent,
                 directives
               )

      strat = final_agent.state.__strategy__

      # Assistant message has only suspend in tool_calls (add was stripped)
      assistant_msgs =
        Enum.filter(strat.conversation.messages, &(&1.role == :assistant))

      all_tool_call_ids =
        assistant_msgs
        |> Enum.flat_map(fn msg -> msg.tool_calls || [] end)
        |> Enum.map(& &1.id)

      assert "call_suspend_1" in all_tool_call_ids
      refute "call_add_1" in all_tool_call_ids

      # Only suspend's real tool_result exists
      assert count_tool_results(strat.conversation, "call_suspend_1") == 1
      assert count_tool_results(strat.conversation, "call_add_1") == 0

      # Conversation can be serialized/deserialized without synthetics
      serialized = Jason.encode!(strat.conversation)
      refute String.contains?(serialized, "not_executed")
      assert {:ok, _} = Jason.decode(serialized)
    end
  end
end
