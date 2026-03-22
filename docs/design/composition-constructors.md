# Composition Constructors

Every composition in Jido Composer — whether a deterministic pipeline or an
LLM-driven orchestration — is built from a small set of fundamental building
blocks. These **composition constructors** are the primitives from which all
workflow shapes are assembled. Understanding them helps you see what the library
can express and where each pattern fits.

## The Five Constructors

There are five constructors for building compositions, plus one escape hatch for
fully dynamic scenarios. Together they cover the full range of workflow patterns.

### Sequence

**Do A, then do B.** The output of A becomes the input to B.

```
A >>> B >>> C
```

This is the most basic form of composition. Each [Node](nodes/README.md)
receives the accumulated [context](nodes/context-flow.md) and adds its result.
If any step fails, the rest are skipped (fail-fast).

In jido_composer, sequence is expressed through FSM transitions:

```elixir
transitions: %{
  {:extract, :ok}   => :transform,
  {:transform, :ok} => :load,
  {:load, :ok}      => :done
}
```

Each transition says "when this state succeeds, go to the next state." The
[Machine](workflow/state-machine.md) walks forward one state at a time.

### Parallel

**Do A and B at the same time, then combine their results.**

```
       ┌─── A ───┐
input ─┤          ├─── merged result
       └─── B ───┘
```

Both branches receive the same input and run concurrently. When both finish,
their results are merged into a single context. This is what
[FanOutNode](nodes/README.md#fanoutnode) provides.

Parallel is for a **fixed, known set of branches** — you declare at definition
time exactly which nodes run side-by-side. Each branch does something different.

```elixir
{:ok, fan_out} = FanOutNode.new(
  name: "parallel_review",
  branches: [
    security: SecurityReviewAction,
    compliance: ComplianceReviewAction,
    performance: PerformanceReviewAction
  ]
)
```

### Choice

**Based on what happened, do A or B (but not both).**

```
             ┌─── A (if :approved)
outcome ─────┤
             └─── B (if :rejected)
```

A previous step produces an [outcome](glossary.md#outcome) — an atom like
`:ok`, `:invalid`, `:approved`, or `:rejected`. The transition table routes to
different next states based on that outcome.

```elixir
transitions: %{
  {:review, :approved} => :publish,
  {:review, :rejected} => :revise,
  {:review, :escalate} => :manager_review
}
```

The set of possible outcomes and branches is declared at definition time. The
_which_ branch runs depends on runtime data, but the _possible_ branches are
all known up front. This is what makes workflows statically analyzable — you
can draw the full graph before running anything.

### Traverse

**Apply the same operation to each item in a collection.**

```
              ┌─── A(item₁) ───┐
[items] ──────┼─── A(item₂) ───┼─── [results]
              └─── A(item₃) ───┘
```

This is the "map" operation — given a list of items from a previous step, run
the same node on each item (potentially in parallel), and collect all results
into a list.

Traverse differs from Parallel in two important ways:

| Aspect          | Parallel (FanOut)        | Traverse (Map)              |
| --------------- | ------------------------ | --------------------------- |
| Branch count    | Fixed at definition time | Determined at runtime       |
| Branch identity | Each branch is different | All branches are the same   |
| Result shape    | Named map of results     | Ordered list of results     |
| Use case        | Heterogeneous tasks      | Homogeneous data processing |

A concrete example: "identify all issues in a document, then for each issue,
generate a fix suggestion." The number of issues is unknown until the first
step runs. Every issue gets the same "generate fix" operation. This is traverse.

> **Status**: Implemented as `MapNode`. See the
> [traverse design](traverse/README.md) for details.

### Identity

**Pass through unchanged.** The input context flows to the output with no
modification. This is the "do nothing" operation.

Identity may seem trivial, but it completes the algebra. It guarantees that
composition has a neutral element: adding a pass-through before or after any
node does not change the result. In practice, identity appears when a workflow
state needs to exist for routing purposes without performing computation.

## The Escape Hatch: Bind

**Compute which workflow to run, then run it.** The next step is determined
entirely by the result of the previous step.

This is what the [Orchestrator](orchestrator/README.md) provides. An LLM reads
the context and decides which tools to invoke, in what order, with what
arguments. The set of _available_ tools is declared, but the _sequence of
invocations_ is decided at runtime.

Bind is strictly more powerful than the five constructors above. With bind, a
step can produce an entirely new composition — not just choose between
pre-declared branches, but construct arbitrary sequences. This power comes at a
cost: you can no longer statically analyze the execution path, because it
depends on runtime decisions.

| Capability            | Five Constructors          | Bind (Orchestrator)    |
| --------------------- | -------------------------- | ---------------------- |
| Static graph          | Yes — all paths known      | No — paths are dynamic |
| Validation before run | Yes                        | Only tool availability |
| Visualization         | Full FSM diagram           | Available tools only   |
| Checkpointing         | Exact position in graph    | Conversation state     |
| Parallelism           | Explicit (FanOut/Traverse) | LLM-decided            |

The five constructors (Workflow) and bind (Orchestrator) are complementary, not
competing. Use the constructors when you know the shape of the computation.
Use bind when the shape must be discovered at runtime.

## How Constructors Compose

The power of these constructors is that they compose freely. Any constructor can
contain any other:

- **Sequence of parallels**: Run three parallel reviews, then aggregate
- **Parallel of sequences**: Run two independent pipelines side-by-side
- **Traverse inside sequence**: Extract items, then process each one
- **Choice after traverse**: If all items pass validation, continue; otherwise
  escalate
- **Bind containing constructors**: An orchestrator invokes a workflow (which
  internally uses sequence, parallel, traverse, and choice)

This recursive composability comes from the [Node](nodes/README.md) abstraction
— every constructor produces a Node, and every constructor accepts Nodes as
inputs. An entire workflow appears as a single Node to its parent composition.

## The Expressiveness Spectrum

The five constructors and bind sit on a spectrum from fully static (all paths
known before execution) to fully dynamic (paths discovered at runtime):

```
More analyzable                                      More expressive
──────────────────────────────────────────────────────────────────────
  Identity   Sequence   Parallel   Choice   Traverse   Bind
     │          │          │         │          │         │
  pass-thru  A then B   A and B   A or B   A per item  compute
                                                        next step
```

Moving right on this spectrum gains expressiveness but loses static guarantees.
The library's two composition patterns correspond to positions on this
spectrum:

- **Workflow** uses Identity, Sequence, Parallel, Choice, and Traverse. The
  execution graph is known before running. You can validate transitions, detect
  dead ends, and visualize the full flow.

- **Orchestrator** adds Bind. The execution path is decided at runtime by the
  LLM. You declare which tools are available, but the LLM chooses which to use
  and when.

This separation is deliberate. Combining both levels in a single abstraction
would either restrict the orchestrator (by requiring pre-declared paths) or
weaken the workflow (by losing static analysis). Keeping them separate
preserves the strengths of each.

## Relationship to Foundations

The [Foundations](foundations.md) document describes the category theory that
makes these constructors work:

| Constructor | Algebraic Structure         | Foundations Reference                                                                 |
| ----------- | --------------------------- | ------------------------------------------------------------------------------------- |
| Sequence    | Kleisli composition (`>=>`) | [Error-Aware Composition](foundations.md#kleisli-category-error-aware-composition)    |
| Parallel    | Product / fan-out (`&&&`)   | [Arrow Combinators](foundations.md#arrow-combinators-parallel-and-fan-out)            |
| Choice      | Coproduct / copairing       | [Enriched Composition](foundations.md#enriched-composition-outcomes-as-coproducts)    |
| Traverse    | Applicative traversal       | _(new — see below)_                                                                   |
| Identity    | Identity morphism           | [The Category: Ctx](foundations.md#the-category-ctx)                                  |
| Bind        | Free category               | [The Orchestrator as Free Category](foundations.md#the-orchestrator-as-free-category) |

Traverse is a new entry in the algebraic model. It corresponds to the
`traverse` operation from category theory: given a morphism `A -> F B` and a
collection `T A`, produce `F (T B)` — apply the morphism to each element and
collect the results. In jido_composer, this means applying a Node to each item
from context and collecting all results into a list.

## Deciding Which Constructor to Use

| Situation                                        | Constructor |
| ------------------------------------------------ | ----------- |
| Steps must run in order, each building on prior  | Sequence    |
| Independent tasks that can run simultaneously    | Parallel    |
| Different paths based on runtime outcome         | Choice      |
| Same operation applied to a variable-length list | Traverse    |
| No computation needed at this step               | Identity    |
| Next step must be decided by AI / external logic | Bind        |

Most workflows combine several constructors. A typical pattern:

1. **Sequence** to set up context
2. **Traverse** to process a list of items from step 1
3. **Choice** to branch based on traverse results
4. **Sequence** to finalize

The constructors are the vocabulary. The workflow definition is the sentence.
