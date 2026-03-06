# Typed I/O (NodeIO)

Different node types produce different output shapes. The NodeIO envelope wraps
node output with type metadata, enabling the composition layer to adapt between
mismatched types while preserving the [monoidal](../foundations.md) structure.

## The Problem

| Producer                                             | Output type           | Consumer expectation                 |
| ---------------------------------------------------- | --------------------- | ------------------------------------ |
| [Orchestrator](../orchestrator/README.md) final text | `String.t()`          | `map()` for deep merge               |
| Object-mode generation                               | `map()` (parsed JSON) | `map()` (but semantically different) |
| [ActionNode](README.md#actionnode)                   | `map()`               | `map()`                              |
| AgentTool result flowing back to the LLM             | `map()`               | Text (for conversation display)      |

When an Orchestrator is nested as a child in a Workflow, the parent receives a
string and tries to deep-merge it. Without type information, this either crashes
or produces unexpected results. The endomorphism monoid technically does not
close.

## The Envelope

NodeIO is a typed envelope that wraps node output with a type tag. The key
property: `to_map/1` is a natural transformation back to `Map`, preserving the
monoidal structure.

| Type      | Value shape  | `to_map/1` result  | Use case                         |
| --------- | ------------ | ------------------ | -------------------------------- |
| `:map`    | `map()`      | The value itself   | ActionNode results (passthrough) |
| `:text`   | `String.t()` | `%{text: value}`   | Orchestrator final answers       |
| `:object` | `map()`      | `%{object: value}` | Object-mode LLM generation       |

An optional `schema` field carries the JSON Schema used for object-mode
validation.

## Adaptation Points

NodeIO is not handled by nodes — it is handled by the **composition layer**.
Nodes continue to return plain maps or text. The composition layer wraps and
unwraps as needed.

| Location                                                          | Direction    | Operation                                                                                     |
| ----------------------------------------------------------------- | ------------ | --------------------------------------------------------------------------------------------- |
| [Machine](../workflow/state-machine.md) `apply_result/2`          | Envelope in  | `to_map/1` before deep merge                                                                  |
| [Orchestrator Strategy](../orchestrator/strategy.md) final answer | Wrap         | Text wrapped as `NodeIO.text/1`                                                               |
| [AgentTool](../orchestrator/README.md#agenttool-adapter) result   | Unwrap       | `unwrap/1` for LLM serialization                                                              |
| [FanOutNode](README.md#fanoutnode) merge                          | Per-branch   | Each branch result resolved via `to_map/1`                                                    |
| `query_sync` / `run_sync` return value                            | Unwrap       | `unwrap/1` for the end user (API unchanged)                                                   |
| Agent boundary (`emit_to_parent`)                                 | Pass-through | NodeIO flows as part of the result signal; parent's `apply_result` resolves it via `to_map/1` |

The adaptation is transparent to both nodes and API consumers. Nodes produce
their natural output type. API consumers receive unwrapped values. Only the
composition layer sees the envelope.

When a child agent returns a NodeIO-wrapped result via `emit_to_parent`, the
parent receives it in `cmd(:child_result)`. The parent's composition layer
(Machine or Orchestrator strategy) resolves the envelope via `to_map/1` before
scoped deep merge — the same path as any other result. The child does not need
to unwrap; the parent does not need to know the child's output type.

## Mergeable Check

Not all NodeIO types can be directly deep-merged into context without
adaptation. The `mergeable?/1` function distinguishes:

| Type      | Mergeable? | Reason                                    |
| --------- | ---------- | ----------------------------------------- |
| `:map`    | Yes        | Already a map — direct deep merge         |
| `:text`   | No         | Must be wrapped in `%{text: ...}` first   |
| `:object` | No         | Must be wrapped in `%{object: ...}` first |

`resolve_result/1` in the Machine handles both `NodeIO` structs and bare maps,
providing backward compatibility.

## Optional Type Declarations

Nodes gain optional callbacks for compile-time validation:

| Callback        | Returns                                  | Purpose              |
| --------------- | ---------------------------------------- | -------------------- |
| `input_type/1`  | `:map` \| `:text` \| `:object` \| `:any` | Expected input type  |
| `output_type/1` | `:map` \| `:text` \| `:object` \| `:any` | Produced output type |

The [Workflow DSL](../workflow/README.md) can warn at compile time when adjacent
nodes have incompatible types. This is a warning, not an error —
`resolve_result/1` handles mismatches at runtime.

## Relationship to the Monoid

The NodeIO envelope does not break the endomorphism monoid — it extends it. The
`to_map/1` function ensures that any typed output can be reduced to a map,
which is then deep-merged as usual. The monoid operation remains
`(Map, deep_merge, %{})`. NodeIO is the adaptation layer that ensures all node
outputs can participate in this operation.

For the full categorical treatment, see
[Foundations — Typed Output and Monoidal Closure](../foundations.md#typed-output-and-monoidal-closure).
