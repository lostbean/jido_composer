# Jido Composer

Composable agent flows via FSM for the [Jido](https://github.com/agentjido/jido) ecosystem.

Jido Composer provides two composition patterns that are mutually composable — a Workflow can contain an Orchestrator, an Orchestrator can invoke a Workflow, and both can nest arbitrarily.

## Patterns

- **Workflow** — Deterministic FSM-based pipeline. Each state binds to an action or sub-agent. Transitions are fully determined by outcomes.
- **Orchestrator** — An agent that uses an LLM to dynamically compose available sub-agents and actions at runtime via a ReAct-style loop.

Both share a **Node** abstraction (uniform `context -> context` interface) and support arbitrary nesting.

## Key Features

- **Uniform Node interface** — Actions, agents, human gates, and fan-out branches all implement the same `context -> context` contract
- **Context accumulation** — Scoped deep merge prevents cross-node key collisions
- **Generalized suspension** — Any node can pause a flow for human input, rate limits, async completion, or external jobs
- **Persistence cascade** — Checkpoint, thaw, and resume agent trees across process restarts with automatic replay of in-flight operations
- **Fan-out with partial completion** — Parallel branches with backpressure, where individual branches can suspend independently
- **LLM integration** — Provider-agnostic via [req_llm](https://hexdocs.pm/req_llm), with tool approval gates and streaming support
- **Pure strategies** — All side effects described as directives; strategies are testable without a running runtime

## Installation

Add `jido_composer` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:jido_composer, "~> 0.1.0"}
  ]
end
```

## Documentation

- [Design Documentation](docs/design/README.md) — Architecture, components, and design decisions
- API docs via `mix docs`
