defmodule Jido.Composer.TestSupport.MockLLM do
  @moduledoc false
  @behaviour Jido.Composer.Orchestrator.LLM

  @doc """
  A mock LLM for testing the Orchestrator Strategy state machine.

  Returns predetermined responses from a response queue stored in the process dictionary.
  Each call to `generate/4` pops the next response from the queue.

  ## Setup

      MockLLM.setup([
        {:final_answer, "Hello!"},
        {:tool_calls, [%{id: "call_1", name: "search", arguments: %{"query" => "test"}}]},
        {:final_answer, "Based on search: ..."}
      ])
  """

  @spec setup([Jido.Composer.Orchestrator.LLM.response()]) :: :ok
  def setup(responses) when is_list(responses) do
    Process.put(:mock_llm_responses, responses)
    Process.put(:mock_llm_calls, [])
    :ok
  end

  @spec calls() :: [map()]
  def calls do
    Process.get(:mock_llm_calls, [])
  end

  @impl true
  def generate(conversation, tool_results, tools, opts) do
    responses = Process.get(:mock_llm_responses, [])

    call_record = %{
      conversation: conversation,
      tool_results: tool_results,
      tools: tools,
      opts: opts
    }

    Process.put(:mock_llm_calls, Process.get(:mock_llm_calls, []) ++ [call_record])

    case responses do
      [] ->
        {:error, :no_mock_responses_remaining}

      [response | rest] ->
        Process.put(:mock_llm_responses, rest)
        updated_conv = (conversation || []) ++ [{:mock_turn, response}]
        {:ok, response, updated_conv}
    end
  end
end
