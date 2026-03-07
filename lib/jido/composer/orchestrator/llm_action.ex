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

  defp build_context(%ReqLLM.Context{} = context, [], _params) do
    context
  end

  defp build_context(%ReqLLM.Context{} = context, tool_results, _params) do
    Enum.reduce(tool_results, context, fn tr, ctx ->
      content = Jason.encode!(tr.result)
      msg = ReqLLM.Context.tool_result(tr.id, tr.name, content)
      ReqLLM.Context.append(ctx, msg)
    end)
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

        {:ok, %{response: resp, conversation: updated_context}}

      :final_answer ->
        {:ok, %{response: {:final_answer, classified.text}, conversation: updated_context}}
    end
  end
end
