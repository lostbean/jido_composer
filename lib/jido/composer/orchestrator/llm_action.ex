defmodule Jido.Composer.Orchestrator.LLMAction do
  @moduledoc false
  # Internal action for executing LLM calls via RunInstruction.
  # Calls ReqLLM directly — no facade module. Dispatches based on
  # `stream` (boolean).

  use Jido.Action,
    name: "orchestrator_llm_generate",
    description: "Internal: calls ReqLLM generation functions",
    schema: []

  @impl true
  def run(params, _context) do
    model = params[:model]
    conversation = params[:conversation]
    tool_results = params[:tool_results] || []
    tools = params[:tools] || []
    stream = !!params[:stream]

    context = build_context(conversation, tool_results, params)
    req_llm_opts = build_req_llm_opts(tools, params)

    if stream do
      do_stream_text(model, context, req_llm_opts)
    else
      do_generate_text(model, context, req_llm_opts)
    end
  end

  # -- Generation modes --

  defp do_generate_text(model, context, opts) do
    case ReqLLM.generate_text(model, context, opts) do
      {:ok, %ReqLLM.Response{} = response} ->
        classify_and_return(response)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_stream_text(model, context, opts) do
    # Collect-then-return: stream internally, return final result
    case ReqLLM.stream_text(model, context, opts) do
      {:ok, stream} ->
        response = Enum.reduce(stream, nil, fn chunk, _acc -> chunk end)
        classify_and_return(response)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -- Context building --

  defp build_context(nil, _tool_results, params) do
    query = params[:query] || "Hello"
    ReqLLM.Context.new([ReqLLM.Context.user(query)])
  end

  defp build_context(%ReqLLM.Context{} = context, [], params) do
    context = strip_orphaned_tool_calls(context)

    case params[:query] do
      q when is_binary(q) and q != "" ->
        ReqLLM.Context.append(context, ReqLLM.Context.user(q))

      _ ->
        context
    end
  end

  defp build_context(%ReqLLM.Context{} = context, tool_results, _params) do
    context
    |> then(fn ctx ->
      Enum.reduce(tool_results, ctx, fn tr, c ->
        ReqLLM.Context.append(c, ReqLLM.Context.tool_result(tr.id, tr.name, tr.result))
      end)
    end)
    |> strip_orphaned_tool_calls()
  end

  # Removes tool_use entries from assistant messages that have no matching
  # tool_result. This keeps the conversation truthful — only tools that were
  # actually executed appear — while satisfying the API contract that every
  # tool_use must have a tool_result.
  defp strip_orphaned_tool_calls(%ReqLLM.Context{messages: messages} = context) do
    result_ids = extract_tool_result_ids(context)

    updated =
      Enum.map(messages, fn
        %{role: :assistant, tool_calls: calls} = msg when is_list(calls) and calls != [] ->
          filtered = Enum.filter(calls, &MapSet.member?(result_ids, &1.id))

          case filtered do
            [] -> %{msg | tool_calls: nil}
            kept -> %{msg | tool_calls: kept}
          end

        msg ->
          msg
      end)

    %{context | messages: updated}
  end

  defp extract_tool_result_ids(%ReqLLM.Context{messages: messages}) do
    messages
    |> Enum.filter(&(&1.role == :tool))
    |> Enum.map(& &1.tool_call_id)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  # -- Option building --

  defp build_req_llm_opts(tools, params) do
    opts = params[:llm_opts] || []

    opts =
      case params[:system_prompt] do
        nil -> opts
        prompt -> Keyword.put(opts, :system_prompt, prompt)
      end

    opts =
      case params[:temperature] do
        nil -> opts
        temp -> Keyword.put(opts, :temperature, temp)
      end

    opts =
      case params[:max_tokens] do
        nil -> opts
        max -> Keyword.put(opts, :max_tokens, max)
      end

    opts =
      case tools do
        [] -> opts
        tools -> Keyword.put(opts, :tools, tools)
      end

    case params[:req_options] do
      nil -> opts
      [] -> opts
      req_opts -> Keyword.put(opts, :req_http_options, req_opts)
    end
  end

  # -- Response classification --

  defp classify_and_return(%ReqLLM.Response{} = response) do
    classified = ReqLLM.Response.classify(response)
    updated_context = response.context

    base = %{
      conversation: updated_context,
      usage: response.usage,
      finish_reason: response.finish_reason
    }

    case classified.type do
      :tool_calls ->
        calls = classified.tool_calls
        reasoning = classified.text

        resp =
          if reasoning != "" do
            {:tool_calls, calls, reasoning}
          else
            {:tool_calls, calls}
          end

        {:ok, Map.put(base, :response, resp)}

      :final_answer ->
        {:ok, Map.put(base, :response, {:final_answer, classified.text})}
    end
  end
end
