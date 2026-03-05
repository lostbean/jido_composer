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
  - [Context Flow](nodes/context-flow.md) — Context accumulation and the
    monoidal merge model
- [Workflow](workflow/README.md) — Deterministic FSM-based pipelines
  - [State Machine](workflow/state-machine.md) — The Machine struct, transitions,
    and terminal states
  - [Strategy](workflow/strategy.md) — Workflow strategy lifecycle and directive
    flow
- [Orchestrator](orchestrator/README.md) — LLM-driven dynamic composition
  - [LLM Integration](orchestrator/llm-behaviour.md) — req_llm facade and
    custom LLM modules
  - [Strategy](orchestrator/strategy.md) — Orchestrator strategy lifecycle and
    ReAct loop
- [Human-in-the-Loop](hitl/README.md) — Human decision gates, approval
  workflows, and long-pause persistence
  - [HumanNode](hitl/human-node.md) — The Node type for human decisions
  - [Approval Lifecycle](hitl/approval-lifecycle.md) — Request/response protocol
  - [Strategy Integration](hitl/strategy-integration.md) — Suspend and resume in
    Workflow and Orchestrator strategies
  - [Persistence](hitl/persistence.md) — Checkpointing, serialization, and
    hibernate/thaw across long pauses
  - [Nested Propagation](hitl/nested-propagation.md) — HITL across recursive
    composition, concurrent work, and cascading cancellation

## Testing

- [Testing Strategy](testing.md) — TDD approach, cassette-based testing with
  ReqCassette, req_options propagation, and streaming constraints

## Reference

- [Glossary](glossary.md) — Domain terms and definitions
