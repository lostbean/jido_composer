#import ".render/designlib.typ": *
#let title = [Jido Composer — migration draft]
#let body = [
  #section(title: "Foundation", lead: "Jido Composer is an Elixir library for combining deterministic workflows and model-selected operations through one node contract.", body: [
    #goal(title: "Compose deterministic and adaptive agent flows")[A consumer can nest workflows and orchestrators in either direction without changing the parent's node contract.]
    #goal(title: "Carry results through nested and paused work")[A consumer can combine sequential, parallel, collection, and human-input operations while retaining their context and failure information.]
    #no-goal(title: "Replace the Jido runtime or its primitives")[Composer does not replace Jido Actions, Agents, AgentServer, Signals, or Persist.]
    #no-goal(title: "Choose host notification and timeout infrastructure")[Notification transport and durable timeout scheduling remain host responsibilities.]
    #invariant(title: "Children cannot update parent ambient context", enforcement: "mechanism")[The composition layer scopes returned results into working context. It never uses a child result to update parent ambient values.]
    #invariant(title: "Suspension does not consume a workflow transition", enforcement: "mechanism")[The reserved suspend outcome holds the current workflow state. A validated resume outcome or timeout outcome selects the next transition.]
    #principle(title: "Keep composition independent of execution choice")[The same configured node participates in deterministic and adaptive compositions through explicit execution contracts.]
    #principle(title: "Describe effects separately from control decisions")[Strategies describe runtime work through directives. Exceptions and unresolved claims about this separation remain explicit in the pending decisions.]
  ])
    #pending-ledger(
      pending-entry(title: "Approve the migrated design before promotion", kind: "ruling", since: "2026-09-02")[The original Markdown remains unchanged. Approval applies to this draft's organization, extracted rationale, and explicit qualifications.],
      pending-entry(title: "Complete implementation conformance and coverage", kind: "ruling", since: "2026-09-02")[The source corpus establishes carried intent. The approved sync corrections describe observed APIs and limitations, supported by 195 focused passing tests and targeted probes. Repository coverage, confirmed behavior areas, and unresolved safety decisions remain incomplete; this is not a clean conformance result.],
    )
  #section(title: "System at a glance", lead: "The core-model context owns shared meaning and execution values. The execution context explains how consumers and runtime integrations operate on them.", visual: diagram(
    altitude: "L1", title: "Composer within its host", accent: "slate", flow: "top-to-bottom",
    nodes: ((id: "consumer", label: "Consumer application", external: true), (id: "composer", label: "Jido Composer"), (id: "jido", label: "Jido runtime and persistence", external: true), (id: "model", label: "Model providers", external: true), (id: "human", label: "Human input and notifications", external: true)),
    edges: (("consumer", "composer", "configure and invoke"), ("composer", "jido", "directives"), ("jido", "composer", "results and signals"), ("composer", "model", "through ReqLLM"), ("human", "composer", "resume")),
    caption: [Composer owns composition rules. The host owns provider credentials, notification delivery, storage configuration, and durable timeout scheduling.],
  ), body: [
    #cards(cols: "2", items: (
      (title: [#ctx("core-model")], body: [Composition definitions, result values, execution lifecycles, approval records, and their relationships.]),
      (title: [#ctx("execution")], body: [Node adapters, strategy protocols, LLM calls, checkpointing, observation, and consumer examples.]),
    ))
    #diagram(altitude: "L2", title: "Two documentation contexts", accent: "slate", nodes: ((id: "core", label: "Core model", tint: "teal"), (id: "execution", label: "Execution", tint: "blue"), (id: "runtime", label: "Host runtime", external: true)), edges: (("execution", "core", "conforms to"), ("execution", "runtime", "adapts to")), caption: [These are documentation boundaries, not a proposed package reorganization. Execution adopts the core model's vocabulary and values; the host performs effects.])
  ])
  #section(title: "Ownership and cross-context contract", lead: "Logical execution owners remain the existing workflow and orchestrator strategies. The core model describes their values without moving implementation ownership.", body: [
    #md-table(3, (
      [Aggregate or value family], [Consistency owner], [Execution participant],
      [Workflow run and Machine], [Workflow strategy], [Workflow DSL and AgentServer],
      [Orchestration run and tool calls], [Orchestrator strategy], [AgentTool, LLMAction, AgentServer],
      [Parallel execution], [Parent strategy's FanOut.State], [FanOutBranch executor],
      [Approval and suspension], [Suspended strategy or held tool call], [HumanNode, notification host, Resume],
      [Checkpoint and child tracking], [Agent lifecycle and parent strategy], [Jido.Persist and AgentServer],
      [Skill definition], [Consumer configuration], [Skill.assemble and DynamicAgentNode],
    ))
    #points(
      [Authority: the strategy accepts or refuses results and resumes before changing its execution value. The runtime executes directives but cannot independently advance the Machine.],
      [Correlation: workflow state and child request ID identify child work; orchestration uses tool call ID; suspension and approval each retain their own request ID. Child references preserve agent module, agent ID, and tag across process replacement.],
      [Mutation: boundaries exchange values or signals. A child returns a result, never a mutable reference to the parent's context.],
      [Failure: node errors retain their original reason. Unmatched workflow transitions fail explicitly; unknown tool and resume identifiers are refused according to the protocol's stated rules.],
      [Idempotency: matching pending IDs prevents stale transitions. Checkpoint compare-and-swap is a separate storage contract; it does not prove exactly-once execution of external effects.],
    )
    #info(title: "Grounding")[A research orchestrator can invoke an ETL workflow as one tool. The tool call ID correlates its answer, while the workflow scopes ExtractAction's records under extract and preserves its own transition history.]
  ])
  #section(title: "Reading and source coverage", lead: "Read the core model first for the shared contract, then execution for the mechanisms and complete integration details.", body: [
    #points(
      [The migration map accounts for all 30 original documents, including both limitation notes and all eight use cases. It distinguishes consolidated content from unresolved source conflicts.],
      [The original glossary is split into project-specific terms. General Jido and engineering concepts are explained at their integration boundary rather than duplicated as project-owned terminology.],
      [Existing rationale is extracted into proposed decision records. No new technology selection or model recommendation is implied by historical example identifiers.],
    )
    #lnk("../MIGRATION.md")[Source-to-section migration map]
    #lnk("../COVERAGE.md")[Documented subsystem coverage]
    #lnk("../BUILD-DESIGN.md")[Reproducible document build]
  ])
  #section(title: "End-to-end walkthrough", lead: "A consumer composes a research coordinator with an ETL workflow and retains one contract across their boundary.", visual: sequence(
    title: "One consumer request", accent: "slate", participants: ((id: "caller", label: "Consumer"), (id: "orch", label: "Orchestrator"), (id: "wf", label: "ETL workflow")),
    steps: (seq-msg("caller", "orch", "query with input context"), seq-msg("orch", "wf", "select ETL tool"), seq-note("wf", [Extract, transform, validate, load.]), seq-msg("wf", "orch", "scoped result or original error", dashed: true), seq-msg("orch", "caller", "final answer or error", dashed: true)),
    caption: [The parent chooses a tool; the child owns its internal sequence. Direct synchronous and AgentServer execution differ in transport, not in the intended composition contract.],
  ), body: [
    #points([AgentNode exposes the configured ETL workflow. The orchestrator correlates its invocation by call ID; the workflow scopes results by state name.], [A child suspension keeps the parent waiting. The accepted result becomes context data and a tool-result message; the final consumer result is unwrapped from NodeIO.])
  ])
]
