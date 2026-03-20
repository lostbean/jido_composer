defmodule Jido.Composer.CassetteHelper do
  @moduledoc false

  @sensitive_headers ["authorization", "x-api-key", "cookie", "set-cookie"]

  @sensitive_patterns [
    {~r/sk-ant-[a-zA-Z0-9_-]+/, "<ANTHROPIC_KEY>"},
    {~r/sk-[a-zA-Z0-9]{20,}/, "<OPENAI_KEY>"},
    {~r/"api_key"\s*:\s*"[^"]+"/, "\"api_key\":\"<REDACTED>\""},
    {~r/Bearer\s+[a-zA-Z0-9._-]+/, "Bearer <TOKEN>"}
  ]

  @doc """
  Returns `:record` or `:replay` based on the `RECORD_CASSETTES` env var.

  When `RECORD_CASSETTES=true`, cassettes are recorded from live API calls.
  Otherwise, existing cassettes are replayed (default for CI and local dev).
  """
  def cassette_mode do
    if System.get_env("RECORD_CASSETTES") == "true", do: :record, else: :replay
  end

  def default_cassette_opts do
    [
      mode: cassette_mode(),
      match_requests_on: [:method, :uri],
      sequential: true,
      filter_request_headers: @sensitive_headers,
      filter_response_headers: @sensitive_headers,
      filter_sensitive_data: @sensitive_patterns
    ]
  end

  @doc """
  Returns cassette opts with a shared session for cross-process scenarios.

  Use this when the code under test spawns child processes (e.g. via
  `Jido.Exec.run`) that also make HTTP requests through the cassette plug.
  The shared session ensures sequential matching works across processes.

  The caller must stop the session after the test (see example).

  ## Example

      session = ReqCassette.Session.start_shared_session()
      try do
        with_cassette("name", CassetteHelper.shared_cassette_opts(session), fn plug ->
          # test code ...
        end)
      after
        ReqCassette.Session.end_shared_session(session)
      end
  """
  def shared_cassette_opts(session) do
    Keyword.put(default_cassette_opts(), :session, session)
  end

  def filter_sensitive(body) when is_binary(body) do
    Enum.reduce(@sensitive_patterns, body, fn {pattern, replacement}, acc ->
      Regex.replace(pattern, acc, replacement)
    end)
  end

  def filter_sensitive(other), do: other
end
