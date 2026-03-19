defmodule Jido.Composer.Workflow.Obs do
  @moduledoc """
  Observability state and span lifecycle for workflow strategies.

  Encapsulates agent and node (tool) span management. Strategy stores a
  single `_obs: %Obs{} | nil` field instead of separate `_obs_*` fields.
  """

  alias Jido.Composer.Context

  defstruct agent_span: nil,
            node_span: nil

  @type t :: %__MODULE__{
          agent_span: term() | nil,
          node_span: term() | nil
        }

  # Telemetry event prefixes
  @agent_prefix [:jido, :composer, :agent]
  @tool_prefix [:jido, :composer, :tool]

  @doc "Returns a fresh Obs struct."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  # -- Agent span --

  @spec start_agent_span(t(), map()) :: t()
  def start_agent_span(%__MODULE__{} = obs, metadata) do
    span_ctx = Jido.Observe.start_span(@agent_prefix, metadata)
    %{obs | agent_span: span_ctx}
  end

  @spec finish_agent_span(t(), map(), map()) :: t()
  def finish_agent_span(obs, state, extra \\ %{})
  def finish_agent_span(%__MODULE__{agent_span: nil} = obs, _state, _extra), do: obs

  def finish_agent_span(%__MODULE__{agent_span: span_ctx} = obs, state, extra) do
    result =
      case state[:machine] do
        %{context: %Context{} = ctx} ->
          Context.to_clean_map(ctx)

        _ ->
          nil
      end

    measurements = Map.merge(%{result: result, status: state[:status]}, extra)

    measurements =
      if state[:status] == :failure and not Map.has_key?(measurements, :error) do
        Map.put(measurements, :error, state[:error_reason] || "workflow failed")
      else
        measurements
      end

    Jido.Observe.finish_span(span_ctx, measurements)
    %{obs | agent_span: nil}
  end

  # -- Node span (emitted as tool-type spans) --

  @spec start_node_span(t(), map()) :: t()
  def start_node_span(%__MODULE__{} = obs, metadata) do
    span_ctx = Jido.Observe.start_span(@tool_prefix, metadata)
    %{obs | node_span: span_ctx}
  end

  @spec finish_node_span(t(), map()) :: t()
  def finish_node_span(%__MODULE__{node_span: nil} = obs, _measurements), do: obs

  def finish_node_span(%__MODULE__{node_span: span_ctx} = obs, measurements) do
    Jido.Observe.finish_span(span_ctx, measurements)
    %{obs | node_span: nil}
  end

  @doc "Extracts the agent name for obs span metadata."
  @spec agent_name(map()) :: String.t()
  def agent_name(agent) do
    case agent do
      %{name: name} when is_binary(name) -> name
      %{id: id} -> id
      _ -> "workflow"
    end
  end
end
