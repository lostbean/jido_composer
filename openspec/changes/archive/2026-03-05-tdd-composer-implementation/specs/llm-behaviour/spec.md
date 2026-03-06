## Reference Documents

Read these before implementing:

- **Design**: `docs/design/orchestrator/llm-behaviour.md` — Complete generate/4 contract, parameter tables, response type diagram, conversation state ownership table, req_options propagation path diagram, streaming/plug constraint, implementation requirements checklist (7 items)
- **Design**: `docs/design/orchestrator/README.md` — AgentTool adapter operations table showing how LLM tool descriptions are generated from Nodes
- **Design**: `docs/design/testing.md` — "ReqCassette Integration" section: how cassettes work, streaming constraint, sensitive data filtering patterns, req_options propagation path diagram
- **PLAN.md**: Steps 8-10 — LLM behaviour definition, cassette recording instructions, reference implementation details
- **Learnings**: `prototypes/learnings.md` — "Schema Conversion — Already Solved" confirms `Jido.Action.Tool.to_tool/1` handles JSON Schema generation
- **Prototype**: `prototypes/test_llm_tool_calling.exs` — 5 tests validating API request with tools, tool_use parsing, tool_result round-trip, conversation serialization, LLM Behaviour pattern against real Claude API

## ADDED Requirements

### Requirement: LLM behaviour defines generate/4 callback

`Jido.Composer.Orchestrator.LLM` SHALL define a behaviour with a single `generate/4` callback.

#### Scenario: Generate callback signature

- **WHEN** a module declares `@behaviour Jido.Composer.Orchestrator.LLM`
- **THEN** it SHALL implement `generate(conversation, tool_results, tools, opts)` returning `{:ok, response, conversation} | {:error, term()}`

### Requirement: LLM response types cover all orchestrator needs

The `generate/4` response SHALL be one of: final answer, tool calls, tool calls with reasoning, or error.

#### Scenario: Final answer response

- **WHEN** the LLM returns a final answer
- **THEN** the response SHALL be `{:final_answer, text}`

#### Scenario: Tool calls response

- **WHEN** the LLM returns tool use requests
- **THEN** the response SHALL be `{:tool_calls, [%{id: id, name: name, arguments: map}]}`

#### Scenario: Tool calls with reasoning

- **WHEN** the LLM returns tool calls with thinking/reasoning text
- **THEN** the response SHALL be `{:tool_calls, calls, reasoning_text}`

#### Scenario: Error response

- **WHEN** the LLM call fails
- **THEN** the response SHALL be `{:error, reason}`

### Requirement: LLM module owns conversation state

The conversation term SHALL be opaque to the strategy — the LLM module owns its internal format.

#### Scenario: First call passes nil conversation

- **WHEN** `generate/4` is called for the first time
- **THEN** `conversation` SHALL be `nil` and the module SHALL initialize its internal state

#### Scenario: Subsequent calls pass opaque conversation

- **WHEN** `generate/4` returns `{:ok, response, updated_conversation}`
- **THEN** the strategy SHALL store `updated_conversation` and pass it back on the next call without inspection

### Requirement: LLM module accepts req_options for test injection

The `opts` keyword list SHALL support a `:req_options` key for injecting test plugs.

#### Scenario: Cassette plug injection via req_options

- **WHEN** `opts` contains `req_options: [plug: cassette_plug, stream: false]`
- **THEN** the LLM module SHALL merge these into its HTTP request options

### Requirement: ClaudeLLM reference implementation

A reference `ClaudeLLM` module SHALL implement the LLM behaviour against the Anthropic Messages API.

#### Scenario: ClaudeLLM parses tool_use content blocks (cassette)

- **WHEN** `generate/4` is called and the API returns `tool_use` content blocks
- **THEN** ClaudeLLM SHALL parse them into `{:tool_calls, calls}` with parsed argument maps

#### Scenario: ClaudeLLM formats tool results for next call (cassette)

- **WHEN** `generate/4` is called with `tool_results` from previous execution
- **THEN** ClaudeLLM SHALL format them as `tool_result` content blocks in the conversation

#### Scenario: ClaudeLLM handles API errors (cassette)

- **WHEN** the API returns an error response (rate limit, invalid request)
- **THEN** ClaudeLLM SHALL return `{:error, reason}` with structured error information
