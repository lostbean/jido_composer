defmodule TravelPlanner.CassetteHelper do
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

  @doc """
  Default cassette options for TravelPlanner integration tests.

  Mirrors the parent repo's `Jido.Composer.CassetteHelper.default_cassette_opts/0`
  but is local to this subproject so the cassette directory resolves under
  `bench/travelplanner/test/cassettes`.
  """
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
  Returns true if a recorded cassette file already exists for the given name.

  Used to skip integration tests when no cassette is available and no API
  key is set to record one.
  """
  def cassette_exists?(name) when is_binary(name) do
    File.exists?(Path.join(["test", "cassettes", "#{name}.json"]))
  end
end
