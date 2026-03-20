# Observability

Jido Composer integrates with OpenTelemetry for distributed tracing. All spans are optional — when OpenTelemetry is not configured, tracing is a no-op with zero overhead.

## Setup

Add the optional dependencies:

```elixir
def deps do
  [
    {:jido_composer, "~> 0.1.0"},
    {:opentelemetry, "~> 1.3"},
    {:opentelemetry_api, "~> 1.2"},
    {:opentelemetry_exporter, "~> 1.6"},
    # If using AgentObs for visualization:
    {:agent_obs, "~> 0.1"}
  ]
end
```

Configure the tracer in your application config:

```elixir
config :jido, :observability,
  tracer: AgentObs.JidoTracer
```

The tracer module must implement the `Jido.Observe.Tracer` behaviour. `AgentObs.JidoTracer` maps Jido's telemetry events to OpenInference-compatible spans.

## Span Hierarchy

### Orchestrator Spans

```
AGENT span (full orchestrator lifecycle)
├── ITERATION span (ReAct iteration 1)
│   ├── LLM span (model call)
│   ├── TOOL span (tool call A)
│   └── TOOL span (tool call B)
├── ITERATION span (iteration 2)
│   ├── LLM span
│   └── TOOL span
```

| Span      | Telemetry Prefix                 | Opened                     | Closed                                       |
| --------- | -------------------------------- | -------------------------- | -------------------------------------------- |
| Agent     | `[:jido, :composer, :agent]`     | `orchestrator_start`       | Final answer or error                        |
| Iteration | `[:jido, :composer, :iteration]` | Before each LLM call       | When all tool results return or final answer |
| LLM       | `[:jido, :composer, :llm]`       | Before LLM instruction     | When LLM result arrives                      |
| Tool      | `[:jido, :composer, :tool]`      | When tool calls dispatched | When tool result arrives                     |

### Workflow Spans

```
AGENT span (full workflow lifecycle)
├── TOOL span (node: extract)
├── TOOL span (node: transform)
└── TOOL span (node: load)
```

Workflow spans are simpler — one agent span containing one tool span per node execution.

### Nested Agent Spans

When an orchestrator calls a workflow as a tool (or vice versa), the child's AGENT span is parented under the parent's TOOL span:

```
Parent AGENT span
├── TOOL span (child agent)
│   └── Child AGENT span        ← parented here
│       ├── TOOL span (step 1)
│       └── TOOL span (step 2)
```

Context propagation works across process boundaries via `OtelCtx.with_parent_context/2`. The parent captures its OTel context when dispatching a tool call, threads it through the `SpawnAgent` directive, and the child attaches it before starting execution.

## Span Measurements

### Agent Span

| Field        | Description                                        |
| ------------ | -------------------------------------------------- |
| `result`     | Final output                                       |
| `status`     | `:completed`, `:error`, `:success`, `:failure`     |
| `iterations` | Total ReAct iterations (orchestrator only)         |
| `tokens`     | `%{prompt, completion, total}` (orchestrator only) |
| `error`      | Error description (when failed)                    |

### LLM Span

| Field             | Description                                   |
| ----------------- | --------------------------------------------- |
| `tokens`          | `%{prompt, completion, total}` from this call |
| `finish_reason`   | `:stop`, `:length`, `:tool_calls`, etc.       |
| `output_messages` | Normalized assistant messages                 |

### Tool Span

| Field       | Description                         |
| ----------- | ----------------------------------- |
| `tool_name` | Name of the dispatched tool or node |
| `result`    | Tool output data                    |
| `status`    | `:ok` or `:error`                   |
| `error`     | Error detail (when failed)          |

## Checkpoint Behavior

When a flow is checkpointed, the `Obs` struct is reset to `Obs.new()`. Spans are not resumed after thaw — a new agent span starts on resume. This ensures span state is always serialization-safe.

## Tracer Mapping

`AgentObs.JidoTracer` maps Jido telemetry prefixes to OpenInference semantic types:

| Jido Prefix                      | AgentObs Type | OpenInference Semantic |
| -------------------------------- | ------------- | ---------------------- |
| `[:jido, :composer, :agent]`     | `:agent`      | Agent span             |
| `[:jido, :composer, :llm]`       | `:llm`        | LLM span               |
| `[:jido, :composer, :tool]`      | `:tool`       | Tool span              |
| `[:jido, :composer, :iteration]` | `:chain`      | Chain span             |

## Interactive Demo

See `livebooks/06_observability.livemd` for a runnable example that traces orchestrator and workflow execution with visualization via AgentObs Phoenix at `localhost:6006`.
