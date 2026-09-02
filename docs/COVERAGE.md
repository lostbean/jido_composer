# Documented subsystem coverage

## Scope

- This map covers the subsystems declared by the original design corpus.
- A bounded code-conformance pass verified relevant implementation paths and applied approved factual corrections; this map is still not a code-derived inventory of every repository file.
- The existing 16 captured classifications are unchanged; no additional coverage scope decision is implied by the correction pass.
- Repository-wide coverage and complete implementation conformance remain unfinished.

## Audit limits

- The breadth pass found actual library code, guides, Livebooks, custom execution tooling, build and quality infrastructure, and agent/tracker integration.
- Tooling, publication, infrastructure, and conventional configuration still require owner-approved captured, standard, or out-of-scope classifications; these are open proposals, not silently omitted or accepted exclusions.
- No stale row for a removed subsystem was found; the map contains zero standard rows and zero out-of-scope rows.
- The 16 captured rows have not passed complete reproduction-depth and callable-surface closure checks.
- The migrated layer has no confirmed behavior-area lists, separately grounded conditional-rule set, or explicit behavior-area inapplicability records; illustrative walkthroughs do not satisfy that inventory.
- Churn ratios are unavailable because the rows lack implementation path bindings and the untracked Typst documents have no committed change baseline.

## Source-scoped map

| Part                                               | Status   | Owning description                                                                           |
| -------------------------------------------------- | -------- | -------------------------------------------------------------------------------------------- |
| Composition definitions, context, outputs, algebra | captured | [Core model](design/core-model/design.typ#context-and-result-transformations)                |
| Entity relationships and execution lifecycles      | captured | [Core lifecycle model](design/core-model/design.typ#lifecycles-and-decision-rules)           |
| Consumer APIs and DSL configuration                | captured | [Consumer interface](design/execution/design.typ#consumer-interface)                         |
| Node contracts and adapters                        | captured | [Node adapters](design/execution/design.typ#node-adapters)                                   |
| FanOut and MapNode                                 | captured | [Parallel and traverse adapters](design/execution/design.typ#parallel-and-traverse-adapters) |
| Workflow Machine and strategy                      | captured | [Workflow protocol](design/execution/design.typ#workflow-strategy-and-runtime-protocol)      |
| Error propagation                                  | captured | [Error preservation](design/execution/design.typ#error-preservation)                         |
| Orchestrator, AgentTool, LLMAction                 | captured | [Model boundary](design/execution/design.typ#orchestrator-strategy-and-model-boundary)       |
| Human input and general suspension                 | captured | [Suspension protocols](design/execution/design.typ#suspension-and-approval-protocols)        |
| Checkpointing, Children, Resume, replay            | captured | [Checkpointing](design/execution/design.typ#checkpointing-and-resumption)                    |
| Dependency limitations                             | captured | [Execution pending ledger](design/execution/design.typ)                                      |
| Skills and DynamicAgentNode                        | captured | [Skill assembly](design/execution/design.typ#skill-assembly-and-dynamic-delegation)          |
| Obs, OtelCtx, telemetry and tracers                | captured | [Observation](design/execution/design.typ#observation-and-diagnostics)                       |
| Dependency and host integration choices            | captured | [Applied design](design/execution/design.typ#applied-design-and-host-responsibilities)       |
| Testing, stubs, cassettes, secret filtering        | captured | [Testing contracts](design/execution/design.typ#testing-contracts)                           |
| Consumer scenarios                                 | captured | [Walkthrough and scenario index](design/execution/design.typ#end-to-end-walkthrough)         |
