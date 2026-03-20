defmodule Jido.Composer.TestSupport.LLMStub do
  @moduledoc false
  # Test helper that provides predetermined LLM responses.
  #
  # Two modes:
  # 1. **Direct mode** — `execute/1` pops from process dictionary queue.
  #    Used by strategy/integration tests that manually drive the directive loop.
  # 2. **Plug mode** — `setup_req_stub/2` registers a Req.Test stub.
  #    Used by DSL query_sync tests where LLMAction.run goes through Req/ReqLLM.

  @spec setup([term()]) :: :ok
  def setup(responses) when is_list(responses) do
    Process.put(:llm_stub_responses, responses)
    Process.put(:llm_stub_calls, [])
    :ok
  end

  @spec calls() :: [map()]
  def calls do
    Process.get(:llm_stub_calls, [])
  end

  @doc """
  Executes a stub LLM call using the params from a RunInstruction's instruction.
  Returns `{:ok, %{response: response, conversation: conv}}` or `{:error, reason}`.
  """
  @spec execute(map()) :: {:ok, map()} | {:error, term()}
  def execute(params) do
    responses = Process.get(:llm_stub_responses, [])

    Process.put(:llm_stub_calls, Process.get(:llm_stub_calls, []) ++ [params])

    case responses do
      [] ->
        {:error, :no_stub_responses_remaining}

      [response | rest] ->
        Process.put(:llm_stub_responses, rest)
        conversation = params[:conversation]
        updated_conv = (conversation || []) ++ [{:stub_turn, response}]

        case response do
          {:error, reason} ->
            {:error, reason}

          response ->
            {:ok, %{response: response, conversation: updated_conv}}
        end
    end
  end

  @doc """
  Sets up a Req.Test stub that serves Anthropic-format responses from a queue.
  Returns `{Req.Test, stub_name}` for use in `req_options: [plug: ...]`.

  The responses are stored in an Agent so they survive across process boundaries.
  """
  def setup_req_stub(stub_name, responses) when is_atom(stub_name) do
    # Use an Agent to store the response queue (accessible from Req.Test callback process)
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    agent_name = Module.concat(LLMStubAgent, stub_name)

    case Agent.start_link(fn -> responses end, name: agent_name) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, pid}} -> Agent.update(pid, fn _ -> responses end)
    end

    Req.Test.stub(stub_name, fn conn ->
      response =
        Agent.get_and_update(agent_name, fn
          [] -> {:empty, []}
          [resp | rest] -> {resp, rest}
        end)

      case response do
        :empty ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            500,
            Jason.encode!(%{
              "type" => "error",
              "error" => %{"type" => "no_stub_responses", "message" => "Queue exhausted"}
            })
          )

        {:final_answer, text} ->
          Req.Test.json(conn, anthropic_text_response(text))

        {:tool_calls, calls} ->
          Req.Test.json(conn, anthropic_tool_calls_response(calls))

        {:error, _reason} ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            500,
            Jason.encode!(%{
              "type" => "error",
              "error" => %{
                "type" => "server_error",
                "message" => "Stubbed error response"
              }
            })
          )
      end
    end)

    {Req.Test, stub_name}
  end

  @doc """
  Like `setup_req_stub/2`, but also captures each request body for later inspection.

  Use `get_captured_requests/1` to retrieve the list of decoded request bodies.
  """
  def setup_req_stub_with_capture(stub_name, responses) when is_atom(stub_name) do
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    agent_name = Module.concat(LLMStubAgent, stub_name)
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    capture_name = Module.concat(LLMStubCapture, stub_name)

    case Agent.start_link(fn -> responses end, name: agent_name) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, pid}} -> Agent.update(pid, fn _ -> responses end)
    end

    case Agent.start_link(fn -> [] end, name: capture_name) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, pid}} -> Agent.update(pid, fn _ -> [] end)
    end

    Req.Test.stub(stub_name, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      Agent.update(capture_name, fn reqs -> reqs ++ [decoded] end)

      response =
        Agent.get_and_update(agent_name, fn
          [] -> {:empty, []}
          [resp | rest] -> {resp, rest}
        end)

      case response do
        :empty ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            500,
            Jason.encode!(%{
              "type" => "error",
              "error" => %{"type" => "no_stub_responses", "message" => "Queue exhausted"}
            })
          )

        {:final_answer, text} ->
          Req.Test.json(conn, anthropic_text_response(text))

        {:tool_calls, calls} ->
          Req.Test.json(conn, anthropic_tool_calls_response(calls))

        {:error, _reason} ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            500,
            Jason.encode!(%{
              "type" => "error",
              "error" => %{
                "type" => "server_error",
                "message" => "Stubbed error response"
              }
            })
          )
      end
    end)

    {Req.Test, stub_name}
  end

  @doc "Returns the list of captured request bodies from `setup_req_stub_with_capture/2`."
  def get_captured_requests(stub_name) when is_atom(stub_name) do
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    capture_name = Module.concat(LLMStubCapture, stub_name)
    Agent.get(capture_name, & &1)
  end

  @doc "Returns Anthropic-format JSON for a text response."
  def anthropic_text_response(text) do
    %{
      "id" => "msg_stub_#{System.unique_integer([:positive])}",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-sonnet-4-20250514",
      "content" => [%{"type" => "text", "text" => text}],
      "stop_reason" => "end_turn",
      "stop_sequence" => nil,
      "usage" => %{"input_tokens" => 10, "output_tokens" => 20}
    }
  end

  @doc "Returns Anthropic-format JSON for a tool_use response."
  def anthropic_tool_calls_response(calls) do
    content =
      Enum.map(calls, fn call ->
        %{
          "type" => "tool_use",
          "id" => call.id,
          "name" => call.name,
          "input" => call.arguments
        }
      end)

    %{
      "id" => "msg_stub_#{System.unique_integer([:positive])}",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-sonnet-4-20250514",
      "content" => content,
      "stop_reason" => "tool_use",
      "stop_sequence" => nil,
      "usage" => %{"input_tokens" => 10, "output_tokens" => 20}
    }
  end
end
