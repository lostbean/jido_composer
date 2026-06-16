defmodule Jido.Composer.E2E.HITLSuspensionE2ETest do
  @moduledoc """
  E2E tests for HITL suspension & resumption with real LLM cassettes.

  Exercises the full suspend → checkpoint → thaw → resume → complete cycle
  with recorded Anthropic API responses. Guards against regressions where
  synthetic tool_results or orphaned tool_use entries pollute the conversation
  on suspension, breaking the Anthropic API contract on resume.
  """
  use ExUnit.Case, async: false

  import ReqCassette

  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.Composer.{CassetteHelper, Checkpoint}

  alias Jido.Composer.TestActions.{
    AskUserAction,
    EchoAction,
    SaveResultAction
  }

  # ── Orchestrator definitions ──

  defmodule HITLOrchestrator do
    @moduledoc false
    use Jido.Composer.Orchestrator,
      name: "hitl_e2e_orchestrator",
      model: "anthropic:claude-sonnet-4-20250514",
      nodes: [AskUserAction],
      termination_tool: SaveResultAction,
      system_prompt: """
      You are a data analyst assistant. You have two tools:
      - ask_user: Ask the user a clarifying question before proceeding.
      - save_result: Save your final analysis result.

      When given a task, ALWAYS call ask_user first to clarify requirements.
      After receiving the user's response, produce your analysis using save_result.
      """,
      max_iterations: 10
  end

  defmodule HITLSiblingOrchestrator do
    @moduledoc false
    use Jido.Composer.Orchestrator,
      name: "hitl_sibling_e2e_orchestrator",
      model: "anthropic:claude-sonnet-4-20250514",
      nodes: [EchoAction, AskUserAction],
      termination_tool: SaveResultAction,
      system_prompt: """
      You are a data processing assistant. You have these tools:
      - echo: Echo a confirmation message back.
      - ask_user: Ask the user a clarifying question.
      - save_result: Save the final result.

      IMPORTANT: When given data to process, you MUST call BOTH echo (to confirm receipt)
      AND ask_user (to ask about output format) IN THE SAME TURN as parallel tool calls.
      After receiving the user's answer, call save_result.
      """,
      max_iterations: 10
  end

  # ── Conversation inspection helpers ──

  defp all_tool_result_ids(%ReqLLM.Context{messages: messages}) do
    messages
    |> Enum.filter(&(&1.role == :tool))
    |> Enum.map(& &1.tool_call_id)
    |> Enum.reject(&is_nil/1)
  end

  defp count_tool_results(%ReqLLM.Context{messages: messages}, tool_call_id) do
    Enum.count(messages, &(&1.role == :tool and &1.tool_call_id == tool_call_id))
  end

  defp all_tool_use_ids(%ReqLLM.Context{messages: messages}) do
    messages
    |> Enum.filter(&(&1.role == :assistant))
    |> Enum.flat_map(fn msg -> msg.tool_calls || [] end)
    |> Enum.map(& &1.id)
  end

  defp assert_no_synthetics(strat) do
    # Scan the full conversation for synthetic markers. Use inspect/2 rather than
    # Jason.encode!/1 because the conversation embeds structs (e.g. ReqLLM.Tool)
    # that don't implement Jason.Encoder; inspect serializes any term to a string,
    # which is all this substring scan needs.
    serialized = inspect(strat.conversation, limit: :infinity, printable_limit: :infinity)

    refute String.contains?(serialized, "not_executed"),
           "Found 'not_executed' synthetic in conversation"

    refute String.contains?(serialized, "SUSPENDED"),
           "Found 'SUSPENDED' synthetic in conversation"
  end

  defp assert_tool_use_result_pairing(strat) do
    use_ids = MapSet.new(all_tool_use_ids(strat.conversation))
    result_ids = MapSet.new(all_tool_result_ids(strat.conversation))

    assert MapSet.subset?(result_ids, use_ids),
           "Orphaned tool_result IDs (no matching tool_use): #{inspect(MapSet.difference(result_ids, use_ids))}"
  end

  # ── Checkpoint/thaw helper ──

  defp checkpoint_and_thaw(agent, orchestrator_module) do
    strat = agent.state.__strategy__

    checkpoint_data = Checkpoint.prepare_for_checkpoint(strat)
    binary = :erlang.term_to_binary(checkpoint_data, [:compressed])
    assert byte_size(binary) > 0

    restored_strat = :erlang.binary_to_term(binary)
    restored_strat = Checkpoint.reattach_runtime_config(restored_strat, [])

    fresh_agent = orchestrator_module.new()
    restored_agent = StratState.put(fresh_agent, restored_strat)

    {restored_agent, binary}
  end

  # ══════════════════════════════════════════════════════════════
  # Test 1: Basic HITL Suspension & Resumption
  # ══════════════════════════════════════════════════════════════

  describe "basic HITL suspension & resumption" do
    test "suspend → resume → complete cycle with real LLM" do
      with_cassette(
        "e2e_hitl_suspension_basic",
        CassetteHelper.default_cassette_opts(),
        fn plug ->
          # Phase 1: query_sync → LLM calls ask_user → suspension
          agent = HITLOrchestrator.new()
          agent = put_in(agent.state.__strategy__.req_options, plug: plug)

          assert {:suspended, agent, suspension} =
                   HITLOrchestrator.query_sync(agent, "Analyze sales data for Q4 2025")

          # Suspension invariants
          strat = agent.state.__strategy__
          assert %Jido.Composer.Suspension{} = suspension

          assert all_tool_result_ids(strat.conversation) == [],
                 "No tool_results should be in conversation at suspension time"

          assert strat.tool_concurrency.pending == []
          assert map_size(strat.suspended_calls) >= 1
          assert_no_synthetics(strat)

          # Phase 2: Resume with user response
          {agent, directives} =
            HITLOrchestrator.cmd(
              agent,
              {:suspend_resume,
               %{
                 suspension_id: suspension.id,
                 data: %{response: "Focus on revenue trends by region"}
               }}
            )

          assert {:ok, final_agent, result} =
                   Jido.Composer.Orchestrator.DSL.__query_sync_loop__(
                     HITLOrchestrator,
                     agent,
                     directives
                   )

          # Completion invariants
          final_strat = final_agent.state.__strategy__
          assert final_strat.status == :completed
          assert is_map(result)
          assert is_binary(result[:answer])
          assert is_binary(result[:analysis])
          assert_no_synthetics(final_strat)
          assert_tool_use_result_pairing(final_strat)

          # No duplicate tool_results
          for id <- all_tool_result_ids(final_strat.conversation) do
            assert count_tool_results(final_strat.conversation, id) == 1,
                   "tool_result #{id} should appear exactly once (no duplicates)"
          end
        end
      )
    end
  end

  # ══════════════════════════════════════════════════════════════
  # Test 2: Checkpoint/Thaw/Resume (Server Restart Simulation)
  # ══════════════════════════════════════════════════════════════

  describe "checkpoint/thaw/resume (server restart simulation)" do
    test "suspend → checkpoint → thaw → resume → complete" do
      with_cassette(
        "e2e_hitl_suspension_checkpoint",
        CassetteHelper.default_cassette_opts(),
        fn plug ->
          # Phase 1: query_sync → suspension
          agent = HITLOrchestrator.new()
          agent = put_in(agent.state.__strategy__.req_options, plug: plug)

          assert {:suspended, agent, suspension} =
                   HITLOrchestrator.query_sync(
                     agent,
                     "Analyze the following sales data: Q4 revenue was $5.2M (North: $2.1M, South: $1.8M, West: $1.3M). " <>
                       "Ask me which region to focus on, then save your analysis."
                   )

          # Verify suspension state
          strat = agent.state.__strategy__
          assert all_tool_result_ids(strat.conversation) == []
          assert strat.tool_concurrency.pending == []
          assert map_size(strat.suspended_calls) >= 1
          assert_no_synthetics(strat)
          original_msg_count = length(strat.conversation.messages)

          # Phase 2: Checkpoint + thaw (simulate server restart)
          {thawed_agent, binary} = checkpoint_and_thaw(agent, HITLOrchestrator)
          assert byte_size(binary) > 0

          # Verify thawed state integrity
          thawed_strat = thawed_agent.state.__strategy__
          assert map_size(thawed_strat.suspended_calls) >= 1
          assert length(thawed_strat.conversation.messages) == original_msg_count

          assert all_tool_result_ids(thawed_strat.conversation) == [],
                 "No tool_results should leak through serialization"

          # Verify the suspension ID is preserved
          original_ids = Map.keys(strat.suspended_calls)
          restored_ids = Map.keys(thawed_strat.suspended_calls)
          assert original_ids == restored_ids

          # Phase 3: Inject cassette plug into thawed agent and resume
          thawed_agent = put_in(thawed_agent.state.__strategy__.req_options, plug: plug)

          {thawed_agent, directives} =
            HITLOrchestrator.cmd(
              thawed_agent,
              {:suspend_resume,
               %{
                 suspension_id: suspension.id,
                 data: %{
                   response:
                     "Focus on the North region. " <>
                       "It had the highest revenue at $2.1M. Now call save_result with your analysis."
                 }
               }}
            )

          assert {:ok, final_agent, result} =
                   Jido.Composer.Orchestrator.DSL.__query_sync_loop__(
                     HITLOrchestrator,
                     thawed_agent,
                     directives
                   )

          # Completion invariants
          final_strat = final_agent.state.__strategy__
          assert final_strat.status == :completed
          assert is_map(result)
          assert is_binary(result[:answer])
          assert is_binary(result[:analysis])
          assert_no_synthetics(final_strat)
          assert_tool_use_result_pairing(final_strat)

          # No duplicate tool_results
          for id <- all_tool_result_ids(final_strat.conversation) do
            assert count_tool_results(final_strat.conversation, id) == 1,
                   "tool_result #{id} should appear exactly once (no duplicates)"
          end
        end
      )
    end
  end

  # ══════════════════════════════════════════════════════════════
  # Test 3: Sibling Tool Calls with Checkpoint (exact bug path)
  # ══════════════════════════════════════════════════════════════

  describe "sibling tool calls with checkpoint (regression guard)" do
    test "LLM calls echo + ask_user in same turn → suspend → checkpoint → thaw → resume → complete" do
      with_cassette(
        "e2e_hitl_suspension_sibling_tools",
        CassetteHelper.default_cassette_opts(),
        fn plug ->
          # Phase 1: query_sync → LLM calls [echo, ask_user] → suspension
          agent = HITLSiblingOrchestrator.new()
          agent = put_in(agent.state.__strategy__.req_options, plug: plug)

          assert {:suspended, agent, suspension} =
                   HITLSiblingOrchestrator.query_sync(
                     agent,
                     "Process this dataset: [revenue: $1.2M, users: 5000, churn: 3%]. " <>
                       "Confirm receipt and ask me about the output format."
                   )

          # Suspension invariants — THE REGRESSION GUARD
          strat = agent.state.__strategy__
          assert %Jido.Composer.Suspension{} = suspension

          assert all_tool_result_ids(strat.conversation) == [],
                 "No tool_results should be in conversation at suspension time (regression: synthetic results)"

          assert strat.tool_concurrency.pending == []
          assert map_size(strat.suspended_calls) == 1
          assert_no_synthetics(strat)

          # Echo's result should be in tool_concurrency.completed (not in conversation)
          echo_completed =
            Enum.any?(strat.tool_concurrency.completed, fn result ->
              result[:name] == "echo" or
                (is_map(result[:result]) and Map.has_key?(result[:result], :echoed))
            end)

          assert echo_completed,
                 "Echo's completed result should be in tool_concurrency.completed"

          # Phase 2: Checkpoint + thaw
          {thawed_agent, _binary} = checkpoint_and_thaw(agent, HITLSiblingOrchestrator)

          # Verify thawed state
          thawed_strat = thawed_agent.state.__strategy__
          assert map_size(thawed_strat.suspended_calls) == 1
          assert all_tool_result_ids(thawed_strat.conversation) == []

          # Phase 3: Inject cassette plug and resume on thawed agent
          thawed_agent = put_in(thawed_agent.state.__strategy__.req_options, plug: plug)

          {thawed_agent, directives} =
            HITLSiblingOrchestrator.cmd(
              thawed_agent,
              {:suspend_resume,
               %{
                 suspension_id: suspension.id,
                 data: %{response: "Format as a markdown table"}
               }}
            )

          assert {:ok, final_agent, result} =
                   Jido.Composer.Orchestrator.DSL.__query_sync_loop__(
                     HITLSiblingOrchestrator,
                     thawed_agent,
                     directives
                   )

          # Completion invariants
          final_strat = final_agent.state.__strategy__
          assert final_strat.status == :completed
          assert is_map(result)
          assert is_binary(result[:answer])
          assert is_binary(result[:analysis])
          assert_no_synthetics(final_strat)
          assert_tool_use_result_pairing(final_strat)

          # No duplicate tool_results
          for id <- all_tool_use_ids(final_strat.conversation) do
            assert count_tool_results(final_strat.conversation, id) <= 1,
                   "tool_use #{id} should have at most 1 tool_result"
          end
        end
      )
    end
  end
end
