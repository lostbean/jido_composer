## Context

jido_composer is a greenfield Elixir library providing two composition patterns (Workflow and Orchestrator) for the Jido agent ecosystem. The full architecture is documented in `docs/design/` and validated via 34 prototype tests against real Jido primitives and Claude API. All dependencies are already in `mix.exs`. The project currently contains only a placeholder module.

The implementation follows strict TDD: tests written first (failing), then implementation to make them pass. Building blocks are implemented bottom-up — pure data structures first, then strategy logic, then DSL macros, then composition, then HITL.

Cassettes (via ReqCassette) are the primary test data source for any HTTP interactions. Mocks are used only for pure strategy logic where the LLM module is not the thing under test.

## Goals / Non-Goals

**Goals:**

- Implement all modules defined in PLAN.md (Steps 1-29)
- Achieve deep test coverage at unit, integration, and end-to-end levels (~95 tests)
- Use TDD throughout — every module has tests written before implementation
- Use cassettes for all LLM/HTTP interactions in tests
- Build bottom-up: pure structs → strategies → DSL → composition → HITL
- Each phase is independently shippable and testable

**Non-Goals:**

- Phoenix integration or web UI
- Database persistence layer (HITL persistence uses Jido's built-in Persist directive)
- Custom LLM provider implementations beyond the ClaudeLLM reference
- Performance optimization beyond what the design already provides
- `run_sync/2` convenience function (deferred — requires mini event loop)
- Streaming mode for AgentNode (deferred to after sync mode works)

## Decisions

### 1. Bottom-up build order over feature-slice approach

**Decision**: Build from pure data structures (Node, Machine) upward through strategies, DSL, composition, and HITL.

**Rationale**: Each layer composes the previous. Testing a strategy requires working Nodes and Machine. Testing composition requires working strategies. This ordering means every test at layer N has fully validated layer N-1 beneath it, reducing debugging surface.

**Alternative considered**: Feature slices (e.g., "implement a complete linear workflow end-to-end first"). Rejected because it would require implementing Node + Machine + Strategy + DSL simultaneously with insufficient isolation testing.

### 2. Stub actions/agents for strategy tests, cassettes for LLM tests

**Decision**: Workflow strategy tests use simple stub Action modules defined in `test/support/`. Orchestrator strategy tests use a MockLLM for state machine logic and cassettes for LLM response parsing.

**Rationale**: Workflow tests have zero HTTP dependency — stubs are simpler and faster. Orchestrator tests need real LLM response structures to validate parsing, but the ReAct loop state machine can be tested with a MockLLM returning predetermined responses.

**Alternative considered**: Cassettes everywhere. Rejected for workflow tests because there's no HTTP to record.

### 3. Separate Machine struct from Strategy

**Decision**: `Workflow.Machine` is a pure struct with pure functions. `Workflow.Strategy` wraps Machine and emits directives. They are separate modules.

**Rationale**: Machine can be tested in complete isolation (no agent infrastructure). Strategy tests focus on directive emission and signal routing. Separation of concerns keeps both testable.

### 4. Five implementation phases with clear gates

**Decision**: Phase 1 (Foundation) → Phase 2 (Workflow) → Phase 3 (Orchestrator) → Phase 4 (Composition) → Phase 5 (HITL). Each phase gate requires `mix precommit` passing.

**Rationale**: Phases align with dependency ordering. Each phase can be committed independently. Later phases can be deferred without affecting earlier work.

### 5. Single test support directory with shared helpers

**Decision**: All test helpers (stub actions, stub agents, MockLLM, cassette helper) live in `test/support/` and are compiled only in test env.

**Rationale**: Centralized helpers prevent duplication across test files. `elixirc_paths(:test)` already includes `test/support/`.

### 6. Cassette recording as explicit separate step

**Decision**: Cassettes are recorded by running tests with `RECORD=true` (or similar env flag) against real APIs. Normal test runs replay from cassettes.

**Rationale**: Keeps CI fast and deterministic. Recording is a manual step when API response formats change.

## Risks / Trade-offs

- **[Jido API changes]** → The library depends on `jido ~> 2.0`, `jido_action ~> 2.0`, `jido_signal ~> 2.0`. Breaking changes in these would require adaptation. Mitigation: Pin to specific minor versions; prototypes validate current API surface.

- **[Cassette staleness]** → Claude API response format could change between recording and testing. Mitigation: Version-tag cassettes; re-record periodically; filter sensitive data via cassette_helper.

- **[Strategy behaviour contract]** → `Jido.Agent.Strategy` callbacks must match exactly. Mitigation: Prototypes (`test_jido_strategy.exs`) have validated the contract. Strategy tests will catch regressions.

- **[Deep merge edge cases]** → Lists overwrite rather than concatenate in deep merge. Mitigation: Scoping prevents cross-node collisions. Documented in design docs. Tests explicitly cover this.

- **[Signal routing no fallback]** → AgentServer has no default route for unknown signal types. Mitigation: DSL auto-generates `signal_routes/1`; strategy tests verify all routes are declared.

- **[HITL complexity]** → HITL spans three layers (Node, Strategy, System) with persistence and nesting. Mitigation: HITL is Phase 5 — built on fully validated foundation. Each HITL sub-feature is independently testable.
