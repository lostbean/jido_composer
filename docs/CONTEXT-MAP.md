# Composer contexts

## Contexts

- [Core model](design/core-model/CONTEXT.typ) owns composition vocabulary, configuration values, execution records, and their relationships.
- [Execution](design/execution/CONTEXT.typ) owns the vocabulary of node adapters, runtime protocols, provider integration, persistence, and instrumentation.

## Relationships

- Execution is **conformist** to the core model: it interprets the core's values without defining a competing meaning for Node, Context, Outcome, or Suspension.
- Execution forms an **anti-corruption layer** at the external Jido and ReqLLM boundaries: it adapts directives, messages, schemas, and output values to the composition contract.
- These contexts organize documentation; they do not introduce new packages or relocate implementation ownership.

## Draft status

- The Typst layer is a migration draft awaiting approval.
- The original Markdown sources remain unchanged during review.
