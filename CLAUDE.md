# jido_composer - Claude Code Project Context

**Composable agent flows via FSM for the Jido ecosystem**

## Quick Start

- **Design**: See `PLAN.md` for architecture, modules, and implementation order
- **Stack**: Pure Elixir library — no Phoenix, no database

## Core Tech Stack

- **Runtime**: Elixir 1.19, Erlang/OTP 28
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

See `PLAN.md` for the complete design.

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

### Code Style

- Max line length: 120 characters
- Follow Elixir conventions and `mix format`
- Prefer explicit errors over silent fallbacks
- Never use `String.to_atom/1` on untrusted input

## File Organization

- **lib/**: Source code (will contain `jido/composer/` modules)
- **test/**: Tests mirroring lib structure
- **test/support/**: Shared test helpers and fixtures

## Common Pitfalls

- Never bypass Nix dev shell for builds (ensures correct BEAM versions)
- Elixir formatting is separate from `nix fmt` (avoids BEAM process conflicts)
- Run `mix precommit` not just `mix test` before committing
