# Jido Composer — Design Documentation

Composable agent flows for the Jido ecosystem.

The goal of Jido Composer is to create **composable systems** — diverse
combinations of agentic workflows that span the full spectrum from fully
deterministic to fully adaptive. The library provides two composition patterns
that are **mutually composable**: a Workflow can contain an Orchestrator, an
Orchestrator can invoke a Workflow, and both can nest arbitrarily. This mutual
composability comes from a single uniform [Node](nodes/README.md) abstraction
shared by all participants.

## Architecture

- [Overview](overview.md) — High-level architecture, principles, and system
  boundaries
- [Foundations](foundations.md) — Category theory underpinnings: monoids, Kleisli
  composition, arrow combinators, and testable algebraic laws
- [Interface](interface.md) — Consumer-facing API, composability principle, and
  control spectrum
- [Composition](composition.md) — Nesting mechanics and cross-boundary
  communication
- [Use Cases](use-cases.md) — Concrete scenarios: ETL pipelines, research
  coordinators, mixed nesting, multi-agent collaboration

## Components

- [Nodes](nodes/README.md) — The uniform `context -> context` interface all
  participants implement
  - [Context Flow](nodes/context-flow.md) — Context accumulation, the monoidal
    merge model, and context layering (ambient/working/fork)
  - [Typed I/O](nodes/typed-io.md) — NodeIO envelope for heterogeneous output
    types, preserving monoidal closure
- [Workflow](workflow/README.md) — Deterministic FSM-based pipelines
  - [State Machine](workflow/state-machine.md) — The Machine struct, transitions,
    and terminal states
  - [Strategy](workflow/strategy.md) — Workflow strategy lifecycle, directive
    flow, and directive-based FanOut
  - [Error Propagation](workflow/error-propagation.md) — Preserving original
    error reasons through the pipeline to callers
- [Orchestrator](orchestrator/README.md) — LLM-driven dynamic composition
  - [LLM Integration](orchestrator/llm-integration.md) — LLMAction calling
    ReqLLM directly, generation modes, and parameter flow
  - [Strategy](orchestrator/strategy.md) — Orchestrator strategy lifecycle and
    ReAct loop
- [Suspension and HITL](hitl/README.md) — Generalized suspension (human input,
  rate limits, async completion), approval workflows, and long-pause persistence
  - [HumanNode](hitl/human-node.md) — The Node type for human decisions
  - [Approval Lifecycle](hitl/approval-lifecycle.md) — Request/response protocol
  - [Strategy Integration](hitl/strategy-integration.md) — Suspend and resume in
    Workflow and Orchestrator strategies, FanOut partial completion
  - [Persistence](hitl/persistence.md) — Three-tier resource management,
    checkpointing, serialization, and hibernate/thaw
  - [Nested Propagation](hitl/nested-propagation.md) — Suspension across
    recursive composition, FanOut branches, concurrent work, and cascading
    cancellation

## Dynamic Composition

- [Skills](skills/README.md) — Reusable capability bundles (prompt + tools)
  for runtime agent assembly via DynamicAgentNode

## Observability

- [Observability](observability.md) — OpenTelemetry span hierarchy, Obs structs,
  OtelCtx context management, tracer integration, and checkpoint serialization

## Testing

- [Testing Strategy](testing.md) — TDD approach, cassette-based testing with
  ReqCassette, req_options propagation, and streaming constraints

## Reference

- [Glossary](glossary.md) — Domain terms and definitions
