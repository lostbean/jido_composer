defmodule Jido.Composer.Integration.OrchestratorSuspensionConversationTest do
  @moduledoc """
  Tests for the conversation integrity invariant on tool suspension.

  After any orchestrator state transition (completion, suspension, error), the
  conversation in `state.conversation` must satisfy the LLM API contract: every
  `tool_use` in an assistant message must have a corresponding `tool_result`
  in the immediately following messages.

  These tests exercise the two root causes:
  1. Completed sibling tool results not flushed to conversation on suspension
  2. Sibling tool directives dropped by early SuspendDirective return
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

  # -- Conversation invariant helpers --

  defp find_orphaned_tool_use_ids(%ReqLLM.Context{messages: messages}) do
    tool_use_ids =
      messages
      |> Enum.filter(&(&1.role == :assistant))
      |> Enum.flat_map(fn msg ->
        (msg.tool_calls || [])
        |> Enum.map(fn tc -> tc.id end)
        |> Enum.reject(&is_nil/1)
      end)
      |> MapSet.new()

    tool_result_ids =
      messages
      |> Enum.filter(&(&1.role == :tool))
      |> Enum.map(& &1.tool_call_id)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    MapSet.difference(tool_use_ids, tool_result_ids)
  end

  defp assert_conversation_integrity!(%ReqLLM.Context{} = conversation) do
    orphaned = find_orphaned_tool_use_ids(conversation)

    assert MapSet.size(orphaned) == 0,
           "Conversation has tool_use IDs without matching tool_result: " <>
             inspect(MapSet.to_list(orphaned))
  end

  defp find_tool_result(%ReqLLM.Context{messages: messages}, tool_call_id) do
    Enum.find(messages, fn msg ->
      msg.role == :tool and msg.tool_call_id == tool_call_id
    end)
  end

  # -- Tests --

  describe "single tool suspension" do
    test "suspend tool has matching tool_result in conversation" do
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
      assert_conversation_integrity!(strat.conversation)
    end
  end

  describe "multi-tool with suspension (completed sibling)" do
    test "completed add result is flushed to conversation when suspend fires" do
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
      assert_conversation_integrity!(strat.conversation)

      # The completed add tool's real result must be present
      assert find_tool_result(strat.conversation, "call_add_1") != nil,
             "Completed sibling tool (add) should have its result flushed to conversation"
    end
  end

  describe "multi-tool with early suspension (unexecuted sibling)" do
    test "suspend first, sibling add never dispatched - both have tool_results" do
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
      assert_conversation_integrity!(strat.conversation)

      # The unexecuted add tool should have a synthetic result
      assert find_tool_result(strat.conversation, "call_add_1") != nil,
             "Unexecuted sibling tool (add) should have a synthetic tool_result"
    end
  end

  describe "three tools with middle suspension" do
    test "echo completes, suspend fires, add never dispatched - all accounted for" do
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
      assert_conversation_integrity!(strat.conversation)

      # echo completed normally
      assert find_tool_result(strat.conversation, "call_echo_1") != nil,
             "Completed tool (echo) should have its result in conversation"

      # add was never dispatched
      assert find_tool_result(strat.conversation, "call_add_1") != nil,
             "Unexecuted tool (add) should have a synthetic result in conversation"
    end
  end
end
