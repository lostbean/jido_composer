defmodule Jido.Composer.Orchestrator.LLM do
  @moduledoc """
  Default LLM facade for orchestrator decision-making via req_llm.

  Wraps `ReqLLM.generate_text/3` to provide the `generate/4` API that the
  Orchestrator Strategy expects. This module IS the default implementation;
  users can supply custom modules with the same `generate/4` signature.

  ## Response Types

  Returns `{:ok, response, conversation}` or `{:error, reason}`.

  Response variants:

  - `{:final_answer, text}` — The LLM has enough information to respond.
  - `{:tool_calls, calls}` — The LLM wants to invoke one or more tools.
  - `{:tool_calls, calls, reasoning}` — Tool calls with accompanying reasoning text.
  """

  @type tool_call :: %{
          id: String.t(),
          name: String.t(),
          arguments: map()
        }

  @type tool_result :: %{
          id: String.t(),
          name: String.t(),
          result: map()
        }

  @type response ::
          {:final_answer, String.t()}
          | {:tool_calls, [tool_call()]}
          | {:tool_calls, [tool_call()], String.t()}
          | {:error, term()}

  @doc """
  Generates an LLM response using req_llm.

  ## Parameters

  - `conversation` — `ReqLLM.Context.t()` or `nil` on the first call.
  - `tool_results` — Normalized results from previous tool executions.
  - `tools` — List of `ReqLLM.Tool.t()` structs.
  - `opts` — Options including `:model`, `:query`, `:system_prompt`, `:req_options`.
  """
  @spec generate(
          ReqLLM.Context.t() | nil,
          [tool_result()],
          [ReqLLM.Tool.t()],
          keyword()
        ) :: {:ok, response(), ReqLLM.Context.t()} | {:error, term()}
  def generate(conversation, tool_results, tools, opts) do
    model = Keyword.fetch!(opts, :model)
    context = build_context(conversation, tool_results, opts)

    req_llm_opts =
      build_req_llm_opts(tools, opts)

    case ReqLLM.generate_text(model, context, req_llm_opts) do
      {:ok, %ReqLLM.Response{} = response} ->
        classify_and_return(response)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -- Private --

  defp build_context(nil, _tool_results, opts) do
    query = Keyword.get(opts, :query, "Hello")
    ReqLLM.Context.new([ReqLLM.Context.user(query)])
  end

  defp build_context(%ReqLLM.Context{} = context, [], _opts) do
    context
  end

  defp build_context(%ReqLLM.Context{} = context, tool_results, _opts) do
    Enum.reduce(tool_results, context, fn tr, ctx ->
      content = Jason.encode!(tr.result)
      msg = ReqLLM.Context.tool_result(tr.id, tr.name, content)
      ReqLLM.Context.append(ctx, msg)
    end)
  end

  defp build_req_llm_opts(tools, opts) do
    req_llm_opts = []

    req_llm_opts =
      case Keyword.get(opts, :system_prompt) do
        nil -> req_llm_opts
        prompt -> Keyword.put(req_llm_opts, :system_prompt, prompt)
      end

    req_llm_opts =
      case Keyword.get(opts, :max_tokens) do
        nil -> req_llm_opts
        max -> Keyword.put(req_llm_opts, :max_tokens, max)
      end

    req_llm_opts =
      case tools do
        [] -> req_llm_opts
        tools -> Keyword.put(req_llm_opts, :tools, tools)
      end

    case Keyword.get(opts, :req_options) do
      nil -> req_llm_opts
      req_opts -> Keyword.put(req_llm_opts, :req_http_options, req_opts)
    end
  end

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

        {:ok, resp, updated_context}

      :final_answer ->
        {:ok, {:final_answer, classified.text}, updated_context}
    end
  end
end
