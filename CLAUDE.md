# jido_composer - Claude Code Project Context

**Composable agent flows via FSM for the Jido ecosystem**

## Quick Start

- **Design**: See `docs/design/` for architecture and design documentation
- **Stack**: Pure Elixir library — no Phoenix, no database

## Core Tech Stack

- **Development runtime**: Elixir 1.20, Erlang/OTP 29
- **Compatibility checks**: See `docs/RUNTIME-COMPATIBILITY.md` for the full-suite CI matrix.
- **Dependencies**: jason, nimble_options, telemetry (jido deps added later)
- **Dev Tooling**: Credo, ExDoc, Nix flake, treefmt, lefthook

## Architecture Overview

jido_composer provides two composition patterns for Jido agents:

1. **Workflow** — Deterministic FSM-based pipeline. Each state binds to an
   action or sub-agent. No LLM decisions; transitions are fully determined by
   outcomes.
2. **Orchestrator** — An agent that uses an LLM (or other decision function) to
   freely compose available sub-agents and actions at runtime.

Both share a **Node** abstraction (uniform `context → context` interface) and
support arbitrary nesting.

## Daily Commands

**Quality checks:**

- `mix precommit` - Full quality gate (formats, docs, compile, lint, test)
- `mix ci` - CI quality gate (read-only checks)
- `mix fmt` - Format all code (Elixir + Nix/YAML/Markdown/JSON via treefmt)
- `mix fmt.check` - Check formatting without modifying
- `mix lint` - Run static analysis (Credo)
- `mix check` - Compile with warnings as errors
- `mix test` - Run tests
- `mix docs` - Generate documentation
- `mix docs.check` - Validate documentation builds without warnings

**Nix:**

- `nix develop` - Enter dev shell
- `nix fmt` - Format Nix/YAML/Markdown/JSON files

## Development Conventions

### Keeping Usage Rules Current

When changes affect the public API (new modules, new DSL options, new node types, changed contracts), update `usage-rules.md` to reflect them. This file is the authoritative reference for how the library is used.

### Git Commit Conventions

**ALWAYS run `mix precommit` before committing.** This must pass cleanly.

**Commit message format:**

- Use conventional commits: `type(scope): description`
- Examples: `feat: add node behaviour`, `fix: resolve transition lookup`
- **No commit footers** - Do not add `Co-Authored-By` or similar footers
- Keep messages clean and concise

### Testing Strategy

- **Unit tests**: Each module has dedicated tests
- **Integration tests**: Composition and nesting scenarios
- Use `test/support/` for shared test helpers
- Tag tests appropriately for filtering
- **Cassettes**: Tests use ReqCassette for recorded HTTP interactions. Never hand-craft cassettes — always record from live API. To re-record: delete the existing cassette files first, then run `RECORD_CASSETTES=true mix test`. Without the env var, tests replay from existing cassettes.

### Code Style

- Max line length: 120 characters
- Follow Elixir conventions and `mix format`
- Prefer explicit errors over silent fallbacks
- Never use `String.to_atom/1` on untrusted input

## Livebooks

Livebooks in `livebooks/` serve as runnable demos, ordered by complexity:

1. `01_etl_pipeline` — Linear workflow (no API key)
2. `02_branching_and_parallel` — Custom outcomes + FanOut (no API key)
3. `03_approval_workflow` — HITL suspend/resume + checkpoint (no API key)
4. `04_llm_orchestrator` — Orchestrator, workflow-as-tool, AgentNode (API key)
5. `05_multi_agent_pipeline` — Full stack: FanOut + agents + HITL + checkpoint (API key)
6. `06_observability` — OpenTelemetry tracing with Arize Phoenix (API key + Phoenix)
7. `07_jido_ai_bridge` — Jido AI agents inside Composer workflows (API key)
8. `08_dynamic_skill_nodes` — Skill assembly + DynamicAgentNode delegation (API key + Phoenix)
9. `09_traverse_and_mapping` — MapNode: mapping actions over runtime collections (no API key)
10. `10_composition_patterns` — Combining constructors, compile-time vs runtime composition (no API key)

**Verify livebooks run correctly:**

- `mix run scripts/run_livemd.exs livebooks/01_etl_pipeline.livemd` — single file
- `mix run scripts/run_livemd.exs livebooks/0[1-3]*.livemd` — non-LLM only
- `mix run scripts/run_livemd.exs livebooks/*.livemd` — all (needs `ANTHROPIC_API_KEY`)

**Arize Phoenix (for observability livebooks):**

- `docker compose up -d` — start Phoenix at `http://localhost:6006`

**Guidelines:**

- Each livebook is one focused use case, not a feature catalog
- Use `{:jido_composer, ">= 0.0.0"}` in `Mix.install` — the runner rewrites it to `path:` for local dev
- Use `IO.puts`/`IO.inspect` for output; Kino widgets are optional (script skips them)
- Use full module paths inside `defmodule` bodies (aliases don't cross module boundaries in Livebook)
- Always verify after editing: `mix run scripts/run_livemd.exs livebooks/<file>.livemd`

## File Organization

- **lib/**: Source code (will contain `jido/composer/` modules)
- **test/**: Tests mirroring lib structure
- **test/support/**: Shared test helpers and fixtures
- **livebooks/**: Runnable demo guides (included in hex docs)
- **scripts/**: Dev-only scripts (not part of the library)

## Common Pitfalls

- Never bypass Nix dev shell for builds (ensures correct BEAM versions)
- Elixir formatting is separate from `nix fmt` (avoids BEAM process conflicts)
- Run `mix precommit` not just `mix test` before committing

<!-- agent-skills:begin -->
<!-- framework-commit: 7aaecc7d4aa642d14d9de465d6437cf8e0e0d858 origin: git@github.com:lostbean/skills.git -->

(machine-owned; do not edit inside this fence — re-run setup to refresh)

## Agent skills

- **Design layer** — `docs/CONTEXT-MAP.md` indexes the design documents. The root is `docs/design/design.typ`; terms are defined in each context's `CONTEXT.typ`; decisions are recorded in `docs/adr/`. Each design document is a chapter of `docs/design/design-layer.pdf`. The current layer is a migration draft, not a promoted or implementation-verified design.
- **Tracker** — local Markdown under `issues/`. Feature documents use `issues/<feature-slug>/PRD.md`; work items use `issues/<feature-slug>/issues/<NN>-<slug>.md`, numbered from `01`. Fetch reads the named file; publishing creates a file in that layout. Work items store `Status: <state-label>` and `Category: <category-label>`; comments append under `## Comments`.
- **AI disclaimer** — AI-authored tracker comments start with `AI-authored:`.

| Role            | Label           |
| --------------- | --------------- |
| needs-triage    | needs-triage    |
| needs-info      | needs-info      |
| ready-for-agent | ready-for-agent |
| ready-for-human | ready-for-human |
| in-progress     | in-progress     |
| done            | done            |
| wontfix         | wontfix         |
| bug             | bug             |
| enhancement     | enhancement     |

- **Design gate** — `nix run .#design-gate-check -- docs/design .` checks render freshness, token coverage, and cross-link integrity across the repository (exit 0 clean, 1 violation, 2 error). The gate is a pinned Nix input, not copied check scripts. `nix run .#design-gate-render -- docs/design docs/design/design-layer.pdf` rebuilds the single rendered document; contexts emit no sibling PDF. A bare `typst compile` is not the gate and omits document-level contracts.
- **Staleness** — many system commits since the design documents last changed indicate a need to reconcile design and code before relying on the layer.

<!-- agent-skills:end -->
