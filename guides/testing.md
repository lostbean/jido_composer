# Testing

Jido Composer provides two test doubles for LLM-dependent code: **ReqCassette** for HTTP replay and **LLMStub** for deterministic strategy tests. Use cassettes for protocol realism, stubs for fast control-flow testing.

## When to Use What

| Approach           | When to use                                                                     | Speed         |
| ------------------ | ------------------------------------------------------------------------------- | ------------- |
| **No double**      | Pure data structures (Machine transitions, context merge, AgentTool conversion) | Fastest       |
| **LLMStub**        | Deterministic strategy tests, directive-loop tests, unit tests                  | Fast          |
| **ReqCassette**    | HTTP boundaries, provider response shapes, integration/e2e paths                | Fast (replay) |
| **Live recording** | Capturing new cassettes from real APIs                                          | Slow          |

## Test Layers

| Layer           | Scope                      | Test doubles            |
| --------------- | -------------------------- | ----------------------- |
| **Unit**        | Single module in isolation | None or LLMStub         |
| **Integration** | Multi-module composition   | LLMStub and/or cassette |
| **End-to-End**  | Full stack through DSL     | Cassette                |

## ReqCassette

[ReqCassette](https://hexdocs.pm/req_cassette) records real HTTP responses and replays them in tests. It works as a Req plug — no global mocking, fully async-safe.

### Recording Workflow

1. Delete existing cassette files (if re-recording)
2. Run with `RECORD_CASSETTES=true mix test`
3. Cassettes are saved to `test/cassettes/`
4. Subsequent runs replay from saved cassettes

### Usage

```elixir
import ReqCassette

test "orchestrator handles query" do
  with_cassette("my_test", CassetteHelper.default_cassette_opts(), fn plug ->
    agent = MyOrchestrator.new()
    {:ok, answer} = MyOrchestrator.query_sync(
      agent,
      "test query",
      %{},
      req_options: [plug: plug]
    )
    assert answer =~ "expected"
  end)
end
```

### Cassette Modes

| Mode      | Behavior                                           |
| --------- | -------------------------------------------------- |
| `:record` | Record if missing, replay if present (development) |
| `:replay` | Replay only, error if missing (CI)                 |
| `:bypass` | Ignore cassettes, always hit network (debugging)   |

### Sensitive Data Filtering

Cassettes automatically filter secrets via `CassetteHelper.default_cassette_opts/0`:

- **Headers**: `authorization`, `x-api-key`, `cookie`
- **Patterns**: Anthropic keys (`sk-ant-*`), OpenAI keys (`sk-*`), Bearer tokens, JSON-embedded keys

Configuration is centralized in `test/support/cassette_helper.ex`.

### Req Options Propagation

The plug flows through the full stack:

```
Test (with_cassette)
  -> Orchestrator DSL (req_options: [plug: plug])
  -> Strategy state
  -> LLMAction.run(req_options: ...)
  -> ReqLLM (req_http_options: ...)
  -> Req (plug: ...)
```

## LLMStub

Queue predetermined LLM responses for tests that don't need HTTP.

### Direct Mode

Uses process dictionary. For strategy tests that manually drive directive loops:

```elixir
alias Jido.Composer.TestSupport.LLMStub

LLMStub.setup([
  {:tool_calls, [%{id: "1", name: "add", arguments: %{"value" => 5, "amount" => 3}}]},
  {:final_answer, "The answer is 8"}
])

result = LLMStub.execute(params)  # pops from queue
```

### Plug Mode

Agent-backed queue serving Anthropic JSON via `Req.Test.stub`. For DSL `query_sync` tests through the full ReqLLM stack:

```elixir
{Req.Test, stub_name} = LLMStub.setup_req_stub(:my_stub, [
  LLMStub.anthropic_tool_calls_response([
    %{id: "1", name: "add", input: %{"value" => 5, "amount" => 3}}
  ]),
  LLMStub.anthropic_text_response("The answer is 8")
])
```

### When to Use Each Mode

| Mode   | Use when                                                        |
| ------ | --------------------------------------------------------------- |
| Direct | Manually calling strategy functions, testing directive emission |
| Plug   | Testing through `query_sync`/`run_sync`, need full Req stack    |

## Key Notes

### Retry Handling

`LLMAction` retries once by default. When stubbing errors, provide 2+ responses to cover the retry:

```elixir
LLMStub.setup([
  {:error, "rate limited"},   # first attempt fails
  {:error, "rate limited"},   # retry also fails
  {:final_answer, "done"}     # won't reach this
])
```

### Streaming Constraint

Streaming uses Finch directly, bypassing Req plugs. When using cassettes or stubs, set `stream: false` (the default). Streaming and plug-based test doubles are incompatible.

### Test Directory Structure

```
test/
├── cassettes/              # Recorded HTTP responses
├── support/
│   ├── test_actions.ex     # Shared test action modules
│   ├── test_agents.ex      # Shared test agent modules
│   ├── llm_stub.ex         # LLMStub module
│   └── cassette_helper.ex  # Cassette configuration
├── jido/composer/
│   ├── node_test.exs
│   ├── node/               # Node-specific tests
│   ├── workflow/            # Workflow tests
│   └── orchestrator/       # Orchestrator tests
├── integration/            # Multi-module tests
└── e2e/                    # Full-stack tests
```
