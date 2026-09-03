defmodule Jido.Composer.OtelTestHelper do
  @moduledoc """
  Test helper for capturing OTel spans via `otel_exporter_pid` and asserting
  parent-child relationships.

  The exporter sends `{:span, SpanRecord}` tuples to the test process.
  SpanRecord is the Erlang `#span{}` record from `otel_span.hrl`:

      {span, trace_id, span_id, tracestate, parent_span_id,
       parent_span_is_remote, name, kind, start_time, end_time,
       attributes, events, links, status, trace_flags,
       is_recording, instrumentation_scope}

  All tests using this helper must be `async: false` — OTel context is process-global.
  """

  require Record

  # Define Elixir record accessors from the Erlang #span{} record
  Record.defrecord(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  @doc """
  Configure OTel to export spans to the test process via `otel_exporter_pid`.

  Returns handler state for cleanup in `teardown_otel/1`.
  """
  def setup_otel_capture(test_pid) do
    Application.ensure_all_started(:opentelemetry)

    # Configure the tracer so Jido.Observe routes through AgentObs.JidoTracer
    Application.put_env(:jido, :observability, tracer: AgentObs.JidoTracer)

    # Point the OTel exporter at the test process
    :otel_batch_processor.set_exporter(:otel_exporter_pid, test_pid)

    # Attach the Phoenix handler that JidoTracer delegates to
    config = %{event_prefix: [:agent_obs]}
    {:ok, handler_state} = AgentObs.Handlers.Phoenix.attach(config)

    handler_state
  end

  @doc """
  Clean up OTel configuration after a test.
  """
  def teardown_otel(handler_state) do
    AgentObs.Handlers.Phoenix.detach(handler_state)

    # Clean up process dictionary keys left by OTel/AgentObs
    Process.get_keys()
    |> Enum.filter(fn
      key when is_atom(key) -> String.starts_with?(Atom.to_string(key), "agent_obs_")
      _ -> false
    end)
    |> Enum.each(&Process.delete/1)

    Application.delete_env(:jido, :observability)
  end

  @doc """
  Receive all `{:span, record}` messages from `otel_exporter_pid`.

  Flushes the OTel processor first to ensure all spans are exported,
  then collects all span messages from the mailbox.
  """
  def collect_spans(timeout \\ 200) do
    # Force flush to ensure spans are exported
    :otel_batch_processor.force_flush(%{reg_name: :otel_batch_processor_global})

    # Give the exporter a moment to deliver messages
    Process.sleep(100)

    collect_span_messages(timeout)
  end

  defp collect_span_messages(timeout) do
    receive do
      {:span, span_record} ->
        [span_record | collect_span_messages(timeout)]
    after
      timeout -> []
    end
  end

  @doc """
  Find a span by name. Returns the first match or nil.
  """
  def find_span(spans, name) when is_binary(name) do
    Enum.find(spans, fn s -> span(s, :name) == name end)
  end

  @doc """
  Find all spans matching a name.
  """
  def find_spans(spans, name) when is_binary(name) do
    Enum.filter(spans, fn s -> span(s, :name) == name end)
  end

  @doc """
  Find a span whose name contains the given substring.
  """
  def find_span_containing(spans, substring) when is_binary(substring) do
    Enum.find(spans, fn s ->
      name = span(s, :name)
      is_binary(name) and String.contains?(name, substring)
    end)
  end

  @doc """
  Extract span_id from a span record.
  """
  def span_id(span_record), do: span(span_record, :span_id)

  @doc """
  Extract parent_span_id from a span record.
  """
  def parent_span_id(span_record), do: span(span_record, :parent_span_id)

  @doc """
  Extract trace_id from a span record.
  """
  def trace_id(span_record), do: span(span_record, :trace_id)

  @doc """
  Extract name from a span record.
  """
  def span_name(span_record), do: span(span_record, :name)

  @doc """
  Extract attributes from a span record.

  OTel stores attributes as an `otel_attributes` struct internally.
  This extracts them as a plain map for easy assertion.
  """
  def span_attributes(span_record) do
    attrs = span(span_record, :attributes)
    otel_attributes_to_map(attrs)
  end

  @doc """
  Assert that `child_span`'s parent_span_id equals `parent_span`'s span_id.
  """
  def assert_parent_child(parent_span, child_span) do
    parent_id = span_id(parent_span)
    child_parent_id = parent_span_id(child_span)

    if parent_id == child_parent_id do
      :ok
    else
      raise ExUnit.AssertionError,
        message: """
        Span parent-child mismatch:
          Parent span: #{inspect(span_name(parent_span))} (span_id: #{inspect(parent_id)})
          Child span:  #{inspect(span_name(child_span))} (parent_span_id: #{inspect(child_parent_id)})
          Expected child's parent_span_id to equal parent's span_id.
        """
    end
  end

  @doc """
  Assert that two spans are siblings (have the same parent_span_id).
  """
  def assert_siblings(span_a, span_b) do
    parent_a = parent_span_id(span_a)
    parent_b = parent_span_id(span_b)

    if parent_a == parent_b do
      :ok
    else
      raise ExUnit.AssertionError,
        message: """
        Spans are not siblings:
          Span A: #{inspect(span_name(span_a))} (parent_span_id: #{inspect(parent_a)})
          Span B: #{inspect(span_name(span_b))} (parent_span_id: #{inspect(parent_b)})
          Expected both to have the same parent_span_id.
        """
    end
  end

  @doc """
  Assert that all spans share the same trace_id.
  """
  def assert_same_trace(spans) do
    trace_ids = Enum.map(spans, &trace_id/1) |> Enum.uniq()

    if length(trace_ids) == 1 do
      :ok
    else
      raise ExUnit.AssertionError,
        message: """
        Spans do not share the same trace_id:
          #{Enum.map_join(spans, "\n  ", fn s -> "#{inspect(span_name(s))}: trace_id=#{inspect(trace_id(s))}" end)}
        """
    end
  end

  @doc """
  Debug helper: print all collected spans with their relationships.
  """
  def debug_spans(spans) do
    IO.puts("\n=== Collected Spans (#{length(spans)}) ===")

    for s <- spans do
      IO.puts("""
        name: #{inspect(span_name(s))}
        span_id: #{inspect(span_id(s))}
        parent_span_id: #{inspect(parent_span_id(s))}
        trace_id: #{inspect(trace_id(s))}
        attributes: #{inspect(span_attributes(s))}
      """)
    end
  end

  # -- Private helpers --

  # Convert OTel attributes to a plain Elixir map.
  # The internal representation varies by OTel version; handle both formats.
  defp otel_attributes_to_map(attrs) when is_map(attrs) do
    # otel_attributes struct: %{map: %{...}, ...}
    case Map.get(attrs, :map) do
      map when is_map(map) -> map
      _ -> attrs
    end
  end

  defp otel_attributes_to_map(attrs) when is_list(attrs) do
    Map.new(attrs)
  end

  defp otel_attributes_to_map({:attributes, _limit, _value_limit, _count, map})
       when is_map(map) do
    map
  end

  defp otel_attributes_to_map(_), do: %{}
end
