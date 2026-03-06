## Reference Documents

- **Design**: `native-agent-composition.md` §3 — NodeIO envelope, integration points, optional type declarations
- **Design**: `docs/design/nodes/typed-io.md` — Full NodeIO design, type table, adaptation points
- **Prototype**: `prototypes/test_node_io_envelope.exs` — 7 passing tests
- **Learnings**: `prototypes/learnings.md` — "@derive Jason.Encoder needed on NodeIO struct"
- **PLAN**: `IMPLEMENTATION_PLAN.md` Phase 2

## ADDED Requirements

### Requirement: NodeIO envelope wraps typed output

`Jido.Composer.NodeIO` SHALL be a struct wrapping node output with type metadata: `:map`, `:text`, or `:object`.

#### Scenario: Wrap a map result

- **WHEN** `NodeIO.map(%{key: "value"})` is called
- **THEN** it SHALL return `%NodeIO{type: :map, value: %{key: "value"}}`

#### Scenario: Wrap a text result

- **WHEN** `NodeIO.text("answer")` is called
- **THEN** it SHALL return `%NodeIO{type: :text, value: "answer"}`

#### Scenario: Wrap an object result with schema

- **WHEN** `NodeIO.object(%{score: 0.9}, %{type: :object, properties: ...})` is called
- **THEN** it SHALL return `%NodeIO{type: :object, value: %{score: 0.9}, schema: ...}`

### Requirement: NodeIO.to_map/1 provides natural transformation to map

`to_map/1` SHALL convert any NodeIO type back to a map suitable for deep merge.

#### Scenario: Map type passes through

- **WHEN** `NodeIO.to_map(NodeIO.map(%{a: 1}))` is called
- **THEN** it SHALL return `%{a: 1}`

#### Scenario: Text type wraps as map

- **WHEN** `NodeIO.to_map(NodeIO.text("hello"))` is called
- **THEN** it SHALL return `%{text: "hello"}`

#### Scenario: Object type wraps as map

- **WHEN** `NodeIO.to_map(NodeIO.object(%{score: 0.9}))` is called
- **THEN** it SHALL return `%{object: %{score: 0.9}}`

### Requirement: NodeIO is JSON serializable

The NodeIO struct SHALL derive `Jason.Encoder` for serialization.

#### Scenario: Jason.encode! succeeds

- **WHEN** `Jason.encode!(NodeIO.text("hello"))` is called
- **THEN** it SHALL produce valid JSON without error

## MODIFIED Requirements

### Requirement: Machine.apply_result resolves NodeIO

`Machine.apply_result/2` SHALL resolve `NodeIO` envelopes via `to_map/1` before scoped deep merge.

#### Scenario: NodeIO.text result resolved in machine

- **WHEN** `Machine.apply_result(machine, NodeIO.text("answer"))` is called
- **THEN** the machine context SHALL contain `%{state_name: %{text: "answer"}}`

#### Scenario: Bare map result unchanged

- **WHEN** `Machine.apply_result(machine, %{key: "value"})` is called
- **THEN** the machine context SHALL contain `%{state_name: %{key: "value"}}` (backward compatible)

### Requirement: Orchestrator wraps final answers as NodeIO.text

The Orchestrator strategy SHALL wrap `{:final_answer, text}` LLM responses as `NodeIO.text(text)` in the strategy result.

#### Scenario: Final answer stored as NodeIO

- **WHEN** the LLM returns `{:final_answer, "The answer is 42"}`
- **THEN** the strategy result SHALL be `%NodeIO{type: :text, value: "The answer is 42"}`

### Requirement: AgentTool unwraps NodeIO for LLM serialization

`AgentTool.to_tool_result/3` SHALL unwrap `NodeIO` envelopes so the LLM receives native types.

#### Scenario: Text NodeIO unwrapped

- **WHEN** `to_tool_result(id, name, {:ok, NodeIO.text("result")})` is called
- **THEN** the result field SHALL be `"result"` (string, not wrapped)

### Requirement: FanOutNode merges heterogeneous NodeIO branches

`FanOutNode.merge_results/2` SHALL handle branches returning `NodeIO` alongside bare maps.

#### Scenario: Mixed branch types

- **WHEN** branch `:a` returns `NodeIO.text("hi")` and branch `:b` returns `%{count: 5}`
- **THEN** the merged result SHALL be `%{a: %{text: "hi"}, b: %{count: 5}}`
