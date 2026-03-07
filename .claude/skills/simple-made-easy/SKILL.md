---
name: simple-made-easy
description: >
  Review code and design documents through the lens of Rich Hickey's "Simple Made Easy" philosophy.
  Analyzes architecture, components, and implementations for unnecessary complexity (complecting),
  and proposes simpler alternatives. Use this skill whenever the user asks to review code, a PR,
  a design document, an RFC, an ADR, or system architecture for simplicity, complexity, coupling,
  complecting, or ease of understanding and evolution. Even if the user just says "review this for me" and
  shares code or a design doc, consider using this skill if the context suggests they care about
  clean, simple, evolvable architecture.
---

# SimpleMadeEasy Review

You are conducting a review of code or design documentation through the lens of
Rich Hickey's "Simple Made Easy" philosophy. Your goal is to help the author see
where their design or implementation has become unnecessarily complex — not
because it's hard, but because things have been braided together (complected)
that don't need to be.

## The Core Distinction: Simple vs. Easy

Before you begin any review, internalize this distinction — it is the foundation
of everything that follows.

**Simple** comes from "sim-plex" — one fold, one braid. Something is simple when
it has one role, one purpose, one concept. Simplicity is objective: you can look
at a component and assess whether it does one thing or many things. Simplicity
is about the artifact itself — its structure, its entanglements.

**Easy** comes from "adjacere" — to lie near. Something is easy when it's
familiar, close at hand, within your current skill set. Ease is relative and
subjective: what's easy for you may not be easy for someone else.

The critical insight: we habitually choose what's easy (familiar frameworks,
patterns we already know, quick shortcuts) and end up with something complex
(tangled, hard to change, hard to reason about). The goal is to choose what's
simple, even when it requires more upfront effort.

**Complect** means to braid or interleave things together. When two concerns
that could be independent are instead entangled, they've been complected. This
is the primary source of accidental complexity in software. Every time you
complect, you make it harder to understand any single part in isolation, harder
to change one part without affecting another, and harder to reuse components in
new contexts.

**Compose** means to place together. Composed things are combined but remain
independent — you can understand each part on its own and rearrange them freely.

## The Simplicity and Complexity Toolkits

Use these as your reference when evaluating constructs in the code or design
under review.

### Constructs That Tend to Complect

| Construct                                | What it complects                                               |
| ---------------------------------------- | --------------------------------------------------------------- |
| Mutable state                            | Value + time; everything that touches it directly or indirectly |
| Objects                                  | State + identity + value; behavior + data                       |
| Methods (on objects)                     | Function + state; often namespaces too                          |
| Inheritance                              | Types; parent and child are braided together                    |
| Syntax-heavy DSLs                        | Meaning + order + parsing                                       |
| Switch/matching on type                  | Who handles it + what it does (multiple pairs braided)          |
| Variables (mutable)                      | Value + time                                                    |
| Imperative loops                         | What you're computing + how you're iterating                    |
| Actors                                   | What is being done + who is doing it                            |
| ORM                                      | Object model + relational model + query language                |
| Conditionals scattered throughout        | Why something happens + the rest of the program flow            |
| Positional arguments                     | Meaning + order                                                 |
| String concatenation for structured data | Data structure + serialization                                  |
| Shared mutable global config             | Every module's behavior + deployment environment                |

### Constructs That Tend Toward Simplicity

| Construct                             | Why it's simpler                           |
| ------------------------------------- | ------------------------------------------ |
| Values (immutable data)               | No time dimension; can be shared freely    |
| Pure functions                        | Input to output; no hidden state           |
| Namespaces                            | Organize without entangling                |
| Plain data (maps, sets, arrays)       | Universal, transparent, no hidden behavior |
| Polymorphism via protocols/interfaces | Dispatch without inheritance hierarchy     |
| Managed references                    | Explicit, controlled state transitions     |
| Set functions / standard library      | Reusable, composable operations            |
| Queues                                | Decouple producers from consumers          |
| Declarative data manipulation         | What, not how                              |
| Rules / constraints                   | Separate policy from mechanism             |
| Transactions / values for consistency | Consistency without locking everything     |

## Sizing the Review: Small vs. Large Scope

Before diving into the analysis, assess the scope of what you're reviewing. The
approach differs significantly depending on whether you're looking at a single
file, a handful of related files, or a large codebase or system design.

### Small Scope (1-5 files, or a single design document)

Handle the review directly. Read everything yourself, follow the steps below,
produce one report. This is the straightforward path for a PR review, a single
service, or an RFC.

### Large Scope (multiple services, packages, or a large repo)

When the review spans a large codebase, a monorepo, or a system with many
interacting services, you need to decompose the work. Trying to review
everything in one pass will produce a shallow analysis that misses the important
structural issues.

The decomposition strategy itself should follow simplicity principles: each unit
of analysis should be independently understandable, and the synthesis should
compose their findings rather than complecting them.

#### Step 0: Reconnaissance and Decomposition

Before analyzing anything in depth, do a quick structural survey:

1. **Map the landscape.** Use Glob and Grep to understand the repo or project
   structure. Identify the major packages, services, modules, or bounded
   contexts. Look at directory structure, build files, import graphs, and
   deployment configurations. For design docs, identify the major subsystems
   described.

2. **Identify natural boundaries.** Look for where the system already has seams
   — separate packages, services, API boundaries, data stores. These are your
   unit-of-analysis candidates. Also look for where seams are _missing_ — a
   single package that imports from everywhere, or a "shared" module that
   everything depends on. Those missing seams are often where the most impactful
   complecting lives.

3. **Define review units.** Break the system into 3-8 review units, each of
   which can be analyzed independently. A review unit might be: a service, a
   package, a bounded context, a layer (e.g., "the data access layer across all
   services"), or a cross-cutting concern (e.g., "how configuration flows
   through the system"). Each unit should be scoped so that a single reviewer
   can understand it without needing to read the entire codebase.

4. **Identify cross-cutting concerns.** Some things can only be seen by looking
   across units: shared dependencies, communication patterns between services,
   data consistency strategies, configuration propagation. Plan a separate
   cross-cutting analysis for these.

#### Step 1: Spawn Subagent Reviews in Parallel

Use the Task tool to launch one subagent per review unit. Each subagent
receives:

- **The skill instructions** (this SKILL.md and the references/ directory)
- **Its specific scope** — which files, packages, or document sections to
  analyze
- **Context about the whole** — a brief description of the overall system so the
  subagent understands where its piece fits, without needing to read everything
- **The output format** — each subagent produces a component-level review
  following the same report structure defined below

Prompt template for each subagent:

```
You are reviewing one component of a larger system through the lens of Rich Hickey's
"Simple Made Easy" philosophy.

SYSTEM CONTEXT:
[Brief 2-3 sentence description of the overall system and its purpose]

YOUR SCOPE:
[Specific files/packages/sections to review]
[What this component is responsible for in the broader system]

ADJACENT COMPONENTS (for context, not for deep analysis):
[List the components this one interacts with and how]

Read the skill instructions at [skill-path]/SKILL.md and the reference material at
[skill-path]/references/complecting-patterns.md. Then analyze your scoped component
and produce a review following the Output Format in the skill.

Focus on complecting issues WITHIN your component, but also flag any places where
your component appears to be complected WITH adjacent components (reaching into their
internals, sharing mutable state, making assumptions about their implementation).

Save the review to: [output-path]/[component-name]-review.md
```

Launch all subagent reviews in the same turn to maximize parallelism.

#### Step 2: Cross-Cutting Analysis

While (or after) the component reviews run, conduct the cross-cutting analysis
yourself or via a dedicated subagent. This covers:

- **Inter-component complecting:** How do the components communicate? Are they
  complected through shared databases, shared mutable state, synchronous call
  chains, or leaked abstractions? Or do they compose through well-defined
  interfaces, queues, and events?
- **Dependency structure:** Draw (mentally or explicitly) the dependency graph.
  Is it a tree or a tangle? Are there circular dependencies? Does every
  component depend on a single "utils" or "common" package that has become a
  junk drawer?
- **Data flow:** How does data move through the system? Does it get transformed
  at each boundary, or do internal representations leak across boundaries? Are
  there places where the same concept has different names or shapes in different
  components?
- **Configuration and environment:** Is configuration simple (read once,
  validate, pass as values) or complected (scattered reads from environment,
  runtime reloading, behavior that changes based on where it's deployed)?
- **Error handling strategy:** Is error handling consistent and composable, or
  does each component handle errors differently, with some swallowing them and
  others leaking implementation details through error messages?

#### Step 3: Synthesize into a Final Report

Once all subagent reviews are complete, read each one and synthesize a
system-level report. The synthesis is not just concatenation — it's a
higher-level analysis that:

- **Elevates systemic issues.** If three components all have the same
  complecting pattern, that's a systemic issue, not three independent ones. Name
  it as such and propose a systemic fix.
- **Identifies the most impactful interventions.** Across all the findings,
  which 3-5 changes would have the biggest positive impact on the system's
  overall simplicity? Prioritize these in the summary.
- **Incorporates cross-cutting findings.** The inter-component analysis often
  reveals the most important issues — the ones that no single-component review
  can see.
- **Preserves component-level detail.** The final report should reference the
  component reviews for detail. Don't try to compress everything into the
  synthesis — link to the component reviews as appendices or supporting
  material.

Use the Output Format below for the synthesis, with these additions:

- Add a "## System-Level Architecture" section after the Overview that maps the
  components and their relationships
- In the Complecting Analysis, tag each issue as "Component-level" or
  "System-level"
- In Simplification Proposals, distinguish between local refactorings (within a
  component) and architectural changes (affecting multiple components)
- Append the individual component reviews as appendices or save them alongside
  the main report

### When the scope is ambiguous

If you're unsure whether to decompose, err toward decomposing. A good heuristic:
if you find yourself skimming code files because there are too many to read
carefully, you need subagents. The whole point of this review is careful,
thoughtful analysis — if you're rushing, you're not doing it justice. Remember:
more things (more review units, each analyzed carefully) can be simpler than
fewer things (one giant review done shallowly).

---

## How to Conduct the Review (Per Unit)

Whether you're reviewing the whole thing yourself (small scope) or a subagent is
reviewing one component (large scope), the analytical steps are the same.

### Step 1: Understand What You're Reviewing

Read the code or document carefully. Before looking for problems, understand the
system's purpose and context. Ask yourself: what problem is this solving, and
for whom?

If the user has provided code files, read them thoroughly. If they've provided a
design document or RFC, read the full thing. Don't skim.

### Step 2: Map the Components and Their Relationships

Identify the key components, modules, or concepts in the system. For each one,
ask:

- Does this component have one role, or has it accumulated multiple
  responsibilities?
- Can I understand this component without understanding the internals of other
  components?
- If I needed to replace this component, how many other things would break?
- Are the boundaries between components aligned with the actual conceptual
  boundaries of the domain?

For design documents, also ask: are the abstractions proposed here aligned with
the real separations in the problem, or are they organized around implementation
convenience?

### Step 3: Identify Complecting

This is the heart of the review. Look for places where independent concerns have
been braided together. Common patterns to watch for:

**State complecting:** A component that mixes "what is the current value" with
"how did we get here" and "what should happen next." Look for objects that are
hard to test because they require elaborate setup — that's a symptom of
complected state.

**Identity complecting:** When "the thing" and "the current value of the thing"
are treated as inseparable. Can you talk about a customer's order history
without having a live customer object? If not, identity and value have been
complected.

**Knowledge complecting (coupling):** Component A knows too much about the
internal workings of component B. Look for: reaching into another module's data
structures, making assumptions about another service's implementation, or having
to change multiple files for a single conceptual change.

**Time complecting:** When the order in which things happen is embedded into the
structure rather than being explicit. Look for: initialization order
dependencies, callback chains that must execute in sequence, or race conditions
that are "solved" by careful ordering.

**What/How complecting:** The business logic is entangled with the mechanism of
execution. Look for: domain rules mixed into HTTP handlers, business validation
inside database queries, or policy decisions made inside infrastructure code.

**Who/What complecting:** The routing of work is braided with the work itself.
Look for: actors or services that can only be called by specific other actors,
or message handlers that know who sent the message and behave differently based
on that.

### Step 4: Assess Impact (Be Pragmatic)

Not every instance of complecting is worth flagging. Focus on the ones that:

- Make the system harder to understand for someone new
- Make it harder to change one thing without breaking another
- Make testing require elaborate setup or mocking
- Will compound as the system grows — small tangles that will become big tangles
- Block the system from evolving in directions it will likely need to

Conversely, some complecting is acceptable when: the scope is tiny and
contained, the alternative would add more indirection than clarity, or the
domain genuinely requires those things to be together.

### Step 5: Propose Simpler Alternatives

For each significant issue you identify, propose a concrete alternative. Don't
just say "decouple these" — show what the decoupled version would look like.
Reference the simplicity toolkit: can mutable state become values? Can an
inheritance hierarchy become protocol-based polymorphism? Can an imperative
process become declarative data transformation?

When proposing refactoring, think in terms of:

- **Decomplecting:** Separating things that are braided together into
  independent components
- **Introducing seams:** Creating boundaries where none exist, so parts can
  evolve independently
- **Making state explicit:** Moving hidden state into visible, managed values
- **Replacing mechanism with data:** Turning behavioral code into data that is
  interpreted
- **Stratification:** Creating clear layers where each layer only depends on the
  one below

For design documents, propose alternative decompositions of the system. Show how
a different set of boundaries would result in simpler components that compose
rather than complect.

## Output Format

Produce a structured markdown report with the following sections. For
small-scope reviews, this is the complete report. For large-scope reviews, each
component subagent produces this structure for its piece, and the synthesis
report adds the system-level sections noted below.

```
# SimpleMadeEasy Review: [Name of system/component/document]

## Overview
Brief summary of what was reviewed and the overall simplicity assessment.
State whether the design/implementation is fundamentally sound with localized
complexity, or whether there are systemic complecting issues.

## System-Level Architecture (large-scope reviews only)
Map the components/services/modules reviewed and their relationships.
Describe the decomposition strategy used for the review (what review units
were defined and why). Note which concerns were analyzed per-component
and which were analyzed cross-cutting.

## Complecting Analysis

### [Issue Title — descriptive name]
- **What's complected:** Which concerns are braided together
- **Where:** File(s), function(s), section(s) of the document
- **Scope:** Component-level / System-level (large-scope reviews only)
- **Impact:** Why this matters — what becomes harder because of this entanglement
- **Severity:** Critical / Significant / Minor
  - Critical: architectural complecting that will compound and become much harder to fix later
  - Significant: makes understanding or changing the system notably harder
  - Minor: localized tangle, low blast radius, but worth noting

(Repeat for each issue found, ordered by severity)

## Simplification Proposals

### [Proposal Title — matching an issue or group of issues above]
- **Target issue(s):** Which complecting issue(s) this addresses
- **Approach:** What the simpler alternative looks like
- **Scope of change:** Local refactoring / Architectural change (large-scope reviews only)
- **Tradeoffs:** What you give up (if anything) and what you gain
- **Sketch:** Pseudocode, diagram description, or concrete code showing the simpler version

(Repeat for each proposal)

## What's Already Simple
Acknowledge what the author got right. Highlight components or decisions
that are well-decomposed, properly decomplected, or demonstrate good
simplicity instincts. This matters — it reinforces good patterns.

## Summary
Top 2-3 recommendations (or top 3-5 for large-scope reviews), prioritized
by impact on the system's ability to be understood and to evolve.

## Component Reviews (large-scope reviews only)
Reference or append the individual component review reports produced by
subagents. These contain the detailed per-component analysis that supports
the findings in this synthesis.
```

## Principles to Keep in Mind

**Simplicity is about the artifact, not the author.** You're evaluating the
structure of the code or design, not the skill of the person who wrote it. Frame
everything in terms of the system's properties, not the author's choices.

**More things can be simpler than fewer things.** Don't conflate "fewer files"
or "fewer abstractions" with simplicity. Sometimes the simple path involves
creating more components, each with a single responsibility, rather than
cramming everything into fewer, larger ones.

**Guard rails, not guard rails with spikes.** The review should help the author
see their work through new eyes. Be direct about problems but generous in
spirit. The goal is to help them build something they can understand and evolve,
not to make them feel bad about their current approach.

**Simple is not the same as familiar.** Something might look unfamiliar (a new
pattern, a different decomposition) and still be simpler. Conversely, a familiar
pattern (MVC, for instance) might be complecting concerns in the specific
context under review.

**Simplicity enables reliability.** The reason we care about all of this is
practical: simpler systems are easier to understand, easier to change, easier to
debug, and easier to extend. When you make the case for simplification, tie it
back to these concrete benefits.

## Reference Material

For deeper guidance on specific topics, see the reference files in the
`references/` directory:

- `references/complecting-patterns.md` — Detailed catalog of complecting
  patterns with code examples and refactoring strategies
