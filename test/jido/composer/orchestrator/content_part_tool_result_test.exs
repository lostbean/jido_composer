defmodule Jido.Composer.Orchestrator.ContentPartToolResultTest do
  @moduledoc """
  Regression test: when a tool action returns a ReqLLM.ToolResult with multimodal
  ContentPart structs (e.g. images + text), the orchestrator must preserve the
  ContentPart types in the conversation's tool result message.

  Currently, build_context in LLMAction calls Jason.encode!(tr.result) before
  passing to ReqLLM.Context.tool_result/3. This collapses ToolResult structs
  into a JSON string, which tool_result/3 then wraps in a single
  ContentPart.text — losing the multimodal type information.

  The fix: pass tr.result directly to tool_result/3 which already dispatches
  on ToolResult structs, lists, binaries, and arbitrary terms.
  """
  use ExUnit.Case, async: true

  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.Composer.TestSupport.LLMStub

  defmodule FileOrchestrator do
    use Jido.Composer.Orchestrator,
      name: "file_orchestrator",
      description: "Orchestrator with a multimodal file-reading tool",
      model: "anthropic:claude-sonnet-4-20250514",
      nodes: [
        Jido.Composer.TestActions.ReadFileAction
      ],
      system_prompt: "You are a helpful assistant that can read files.",
      max_iterations: 5
  end

  describe "multimodal tool results (regression)" do
    test "ToolResult with ContentParts are preserved in the conversation" do
      plug =
        LLMStub.setup_req_stub(:content_part_regression, [
          {:tool_calls, [%{id: "call_1", name: "read_file", arguments: %{"file_id" => 42}}]},
          {:final_answer, "The file contains a PNG image."}
        ])

      agent = FileOrchestrator.new()
      agent = put_in(agent.state.__strategy__.req_options, plug: plug)

      assert {:ok, agent, "The file contains a PNG image."} =
               FileOrchestrator.query_sync(agent, "Read file 42")

      strat = StratState.get(agent)
      messages = strat.conversation.messages

      # Find the tool result message for our call
      tool_result_msg =
        Enum.find(messages, fn msg ->
          msg.role == :tool and msg.tool_call_id == "call_1"
        end)

      assert tool_result_msg != nil, "Expected a tool result message for call_1"

      # The tool result message should contain an :image ContentPart,
      # not just a :text ContentPart with JSON-encoded data.
      content_types = Enum.map(tool_result_msg.content, & &1.type)

      assert :image in content_types,
             "Expected an :image ContentPart in tool result, but got types: #{inspect(content_types)}. " <>
               "This means the ToolResult was JSON-serialized instead of being dispatched " <>
               "through ReqLLM.Context.tool_result/3's ToolResult clause."
    end
  end
end
