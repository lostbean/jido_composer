# Design migration record

## Status and source authority

- The source corpus contains 30 Markdown files and 6,715 lines.
- The full corpus was read before authoring the Typst draft.
- The initial migration consolidated documented intent rather than deriving a replacement design from implementation.
- An owner-approved sync correction pass now qualifies selected contracts against code and tests; unchanged source intent remains authoritative where differences require a decision.
- The original files remain unchanged until the new layer is approved.
- The draft's pending entries opened on 2026-09-02; that date is not a claimed discovery date for the older defects.

## Source map

| Original source under docs/design                                                         | New home                                                                                      | Treatment                                                                                           |
| ----------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| [README.md](design/README.md)                                                             | [Root orientation](design/design.typ#system-at-a-glance)                                      | Consolidated index and purpose                                                                      |
| [overview.md](design/overview.md)                                                         | [Applied design](design/execution/design.typ#applied-design-and-host-responsibilities)        | Boundaries, dependencies, strategies, signals, errors                                               |
| [foundations.md](design/foundations.md)                                                   | [Composition algebra](design/core-model/design.typ#composition-operations-and-algebra)        | Interpretations and laws retained with explicit proof limits                                        |
| [interface.md](design/interface.md)                                                       | [Consumer interface](design/execution/design.typ#consumer-interface)                          | API and configuration consolidated                                                                  |
| [composition.md](design/composition.md)                                                   | [Ownership contract](design/design.typ#ownership-and-cross-context-contract)                  | Nesting, context direction, runtime and direct-path distinction                                     |
| [composition-constructors.md](design/composition-constructors.md)                         | [Composition operations](design/core-model/design.typ#composition-operations-and-algebra)     | Five constructors and runtime bind                                                                  |
| [glossary.md](design/glossary.md)                                                         | [Core terms](design/core-model/CONTEXT.typ), [execution terms](design/execution/CONTEXT.typ)  | Project terms separated from general external terminology                                           |
| [use-cases.md](design/use-cases.md)                                                       | [Scenario index](design/execution/design.typ#end-to-end-walkthrough)                          | All eight scenarios retained; one canonical code example; full historical sketches remain in source |
| [nodes/README.md](design/nodes/README.md)                                                 | [Adapters](design/execution/design.typ#node-adapters)                                         | Callback contract, mode limitations, Jido AI bridge                                                 |
| [nodes/context-flow.md](design/nodes/context-flow.md)                                     | [Context transformations](design/core-model/design.typ#context-and-result-transformations)    | Scoping, deep merge, ambient, fork                                                                  |
| [nodes/typed-io.md](design/nodes/typed-io.md)                                             | [Output adaptation](design/core-model/design.typ#output-adaptation)                           | Type conversions and sync-path differences                                                          |
| [workflow/README.md](design/workflow/README.md)                                           | [Workflow configuration](design/execution/design.typ#workflow-configuration)                  | Compile checks and generated entry points                                                           |
| [workflow/state-machine.md](design/workflow/state-machine.md)                             | [Workflow lifecycle](design/core-model/design.typ#workflow-run-lifecycle)                     | Fields, operations, fallback order, terminals                                                       |
| [workflow/strategy.md](design/workflow/strategy.md)                                       | [Workflow protocol](design/execution/design.typ#workflow-strategy-and-runtime-protocol)       | State, routes, polymorphic dispatch, parallel tracking                                              |
| [workflow/error-propagation.md](design/workflow/error-propagation.md)                     | [Error preservation](design/execution/design.typ#error-preservation)                          | Capture points, nested errors, span closure, nil ambiguity                                          |
| [orchestrator/README.md](design/orchestrator/README.md)                                   | [Orchestrator configuration](design/execution/design.typ#orchestrator-configuration)          | Runtime overrides, metadata rebuild, rationale                                                      |
| [orchestrator/strategy.md](design/orchestrator/strategy.md)                               | [Orchestrator boundary](design/execution/design.typ#orchestrator-strategy-and-model-boundary) | State, routes, concurrency, termination, restore                                                    |
| [orchestrator/llm-integration.md](design/orchestrator/llm-integration.md)                 | [LLMAction boundary](design/execution/design.typ#llmaction-boundary)                          | Options, classification, conversation, streaming                                                    |
| [hitl/README.md](design/hitl/README.md)                                                   | [Suspension protocols](design/execution/design.typ#suspension-and-approval-protocols)         | Reasons and ownership; reserved outcome wording corrected against detailed protocol                 |
| [hitl/human-node.md](design/hitl/human-node.md)                                           | [Human adapter](design/execution/design.typ#human-input-adapter)                              | Fields, defaults, request construction, advisory-tool conflict                                      |
| [hitl/approval-lifecycle.md](design/hitl/approval-lifecycle.md)                           | [Approval model](design/core-model/design.typ#definitions-and-values)                         | Request/response fields and validation; old route names flagged                                     |
| [hitl/strategy-integration.md](design/hitl/strategy-integration.md)                       | [Suspension protocols](design/execution/design.typ#suspension-and-approval-protocols)         | General resume, gating, sibling policies, FanOut suspension                                         |
| [hitl/persistence.md](design/hitl/persistence.md)                                         | [Checkpointing](design/execution/design.typ#checkpointing-and-resumption)                     | Storage, replay, claim lifecycle, closure and PID limits                                            |
| [hitl/nested-propagation.md](design/hitl/nested-propagation.md)                           | [Nested pauses](design/execution/design.typ#parallel-and-nested-pauses)                       | Isolation, concurrent requests, race conditions, cancellation                                       |
| [limitations/otp-hibernate-support.md](design/limitations/otp-hibernate-support.md)       | [Execution pending ledger](design/execution/design.typ)                                       | Current no-op retained; two upstream alternatives remain unselected                                 |
| [limitations/parent-ref-pid-stripping.md](design/limitations/parent-ref-pid-stripping.md) | [Checkpoint data](design/execution/design.typ#checkpoint-data-and-serialization)              | Requirement distinguished from reported dependency defect                                           |
| [skills/README.md](design/skills/README.md)                                               | [Skill assembly](design/execution/design.typ#skill-assembly-and-dynamic-delegation)           | Fields, prompt assembly, union, registry, extensions                                                |
| [traverse/README.md](design/traverse/README.md)                                           | [Parallel and traverse](design/execution/design.typ#parallel-and-traverse-adapters)           | Input convention, empty case, ordered collection, exclusions                                        |
| [observability.md](design/observability.md)                                               | [Observation](design/execution/design.typ#observation-and-diagnostics)                        | Span hierarchy, propagation, measurements, optional dependency                                      |
| [testing.md](design/testing.md)                                                           | [Testing](design/execution/design.typ#testing-contracts)                                      | Test layers, cassette/stub contracts, HTTP plumbing, filtering                                      |

## Deliberate qualifications

- The shared core-model scope was approved before drafting.
- The census separates logical configuration and progress without claiming that new implementation structs exist.
- General mathematical claims remain interpretations or proposed laws until their preconditions are settled.
- Generalized suspension routes are the canonical draft presentation; legacy HITL names remain a pending compatibility decision.
- Detailed persistence statements take precedence over older summaries claiming three working tiers.
- The claim of strict strategy purity is qualified by documented inline termination and observation effects.
- Exactly-once side effects are not inferred from checkpoint claims or request ID matching.
- Example output-to-outcome adapters and outdated constructor sketches are identified rather than invented.
- No source-described future feature is converted into a build commitment without an owner decision.

## Remaining acceptance work

- Review the rendered document and pending decisions.
- Approve promotion before replacing the original Markdown entry point.
- Complete implementation conformance, repository coverage, and confirmed behavior-area inventories before treating the layer as a complete description of the built system.

## Approved code-conformance corrections

- The 2026-09-02 correction pass changes documentation only; it neither promotes the draft nor changes application behavior.
- Foundation blocks and the 30 original Markdown files remain unchanged.
- Existing safety and intent rulings remain open; a new ruling retains the source's structured-error and MapNode contracts where implementation evidence does not establish them.

| Contract                    | Corrected description                                                                                                                                              | Evidence                                                                                                                                                                                                                                                                                    |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Resume API                  | Agent value or nil, required delivery callback, optional thaw and storage callbacks; no built-in registry lookup or process startup                                | [Resume](../lib/jido/composer/resume.ex), [Resume tests](../test/jido/composer/resume_test.exs)                                                                                                                                                                                             |
| Collection behavior         | MapNode supports ordered partial collection and treats non-list input as empty; direct and directive context inputs differ                                         | [MapNode](../lib/jido/composer/node/map_node.ex), [Cross-feature tests](../test/integration/workflow_map_node_cross_feature_test.exs)                                                                                                                                                       |
| Child lifecycle             | Result acceptance clears phase; normal exit completes and abnormal exit fails                                                                                      | [Children](../lib/jido/composer/children.ex), [Children tests](../test/jido/composer/children_test.exs)                                                                                                                                                                                     |
| Persistence limitations     | Default checkpoints omit Composer preparation; parent PID retention, stop-after-persistence-failure, and unchecked final claim updates remain explicit limitations | [Checkpoint executor](../lib/jido/composer/directive/checkpoint_and_stop_exec.ex), [Checkpoint](../lib/jido/composer/checkpoint.ex), [Resume](../lib/jido/composer/resume.ex)                                                                                                               |
| Replay precedence           | Struct fallback uses ChildRef phases when no spawning tags exist; legacy flat fallback requires an empty phase map                                                 | [Checkpoint](../lib/jido/composer/checkpoint.ex)                                                                                                                                                                                                                                            |
| Public and helper contracts | Workflow schema, configurable max_iterations, queue limits, and Skill/DynamicAgentNode failure paths are documented                                                | [Workflow DSL](../lib/jido/composer/workflow/dsl.ex), [Configure](../lib/jido/composer/orchestrator/configure.ex), [ToolConcurrency](../lib/jido/composer/tool_concurrency.ex), [Skill](../lib/jido/composer/skill.ex), [DynamicAgentNode](../lib/jido/composer/node/dynamic_agent_node.ex) |

- Independent source review restored FanOut's non-tool restriction, the Error class/diagnostic requirements, and MapNode observation requirements.
- The core model overview now names the census's run aggregates and NodeIO, with explicit recursive node containment; separate diagrams preserve legibility.
- Consumer interface pagination keeps its opening table with its section rather than leaving an isolated table header.

## Verification boundary

- The audit ran 195 focused existing tests successfully with recorded or stubbed traffic; it did not run the full application quality gate.
- An initial test attempt encountered an empty inherited API key; successful reruns supplied a non-secret dummy key for recorded traffic.
- In-memory probes confirmed parent PID retention, omitted default checkpoint markers, exact-atom approval gating, result/exit lifecycle separation, mixed-wait status, and ignored final claim-update failure.
- Mechanical design validation checks document structure and freshness; it does not certify behavior, coverage, replay safety, or pending owner decisions.
- No complete conformance claim is made: coverage remains source-scoped and no confirmed behavior-area or rule inventory has been approved.
