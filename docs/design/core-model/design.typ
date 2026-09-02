#import "../.render/designlib.typ": *
#let title = [Core model]
#let body = [
  #section(title: "Foundation", lead: "The core model describes the values shared by all compositions and the rules that transform them.", body: [
    #goal(title: "Keep nested compositions substitutable")[A parent consumes a node result without knowing the child's internal strategy.]
    #no-goal(title: "Introduce replacement runtime entities")[The census is a logical view of existing documented values. Separating configuration from execution here does not mandate splitting an Elixir struct.]
    #invariant(title: "Result adaptation precedes scoped accumulation", enforcement: "mechanism")[The composition owner resolves a result into a map before storing it under the node's scope.]
    #invariant(title: "Only declared resume outcomes advance human work", enforcement: "mechanism")[Human resume checks request identity, permitted decision, and response data before applying a transition.]
    #principle(title: "Separate definitions from execution history")[Configuration describes possible work; execution values record progress; events record what was received or happened.]
  ])
    #pending-ledger(
      pending-entry(title: "Settle the scope of the algebraic laws", kind: "ruling", since: "2026-09-02")[The foundations assert an endomorphism monoid and associative deep merge. Context Flow permits repeated scopes and replacement of non-map values; the laws need explicit preconditions and an identity operation compatible with scoping.],
      pending-entry(title: "Specify approval withdrawal after dispatch", kind: "ruling", since: "2026-09-02")[The sources define rejection before execution and sibling cancellation. They do not define revoking an already accepted approval while the approved call executes. No revocation behavior is invented here.],
    )
  #pagebreak()
  #section(title: "System at a glance", lead: "Composition is one domain: definitions select operations, execution state tracks them, and results supply the facts for the next decision.", visual: diagram(
    altitude: "L4", title: "Definitions and recursive composition", accent: "teal", flow: "top-to-bottom",
    nodes: ((id: "definition", label: "Composition definition"), (id: "node", label: "Node specification"), (id: "skill", label: "Skill"), (id: "workflow", label: "Workflow run"), (id: "orchestration", label: "Orchestration run"), (id: "context", label: "Context"), (id: "io", label: "NodeIO")),
    edges: (("definition", "node", "references"), ("node", "node", "contains children"), ("skill", "node", "provides"), ("workflow", "definition", "uses"), ("orchestration", "definition", "uses"), ("workflow", "context", "owns"), ("orchestration", "context", "owns"), ("io", "context", "adapted into")),
    caption: [The two run aggregates each use one composition definition and one Context. A definition references zero or more Node specifications; a specification can recursively contain child specifications. Skill supplies reusable operations. NodeIO is adapted before scoped accumulation.],
  ), body: [
    #pagebreak()
    #diagram(altitude: "L4", title: "Run-owned progress and human continuation", accent: "teal", flow: "top-to-bottom",
      nodes: ((id: "workflow", label: "Workflow run"), (id: "orchestration", label: "Orchestration run"), (id: "call", label: "Tool call"), (id: "parallel", label: "Parallel execution"), (id: "child", label: "ChildRef"), (id: "pause", label: "Suspension"), (id: "request", label: "ApprovalRequest"), (id: "response", label: "ApprovalResponse")),
      edges: (("orchestration", "call", "owns"), ("workflow", "parallel", "owns"), ("workflow", "child", "tracks"), ("orchestration", "child", "tracks"), ("workflow", "pause", "waits on"), ("call", "pause", "may wait on"), ("call", "request", "may require"), ("pause", "request", "may contain"), ("response", "request", "addresses")),
      caption: [The workflow strategy owns parallel collection progress. Both run aggregates track child references. An orchestration owns zero or more Tool calls; a held call has at most one current ApprovalRequest and a paused call at most one current Suspension. A human suspension contains one request; each ApprovalResponse addresses one request. These two views together index the complete census below.],
    )
    #points(
      [#ctx("core-model") owns these descriptions. #ctx("execution") supplies the operations that realize them through the existing strategy and runtime APIs.],
      [Configuration, progress, and observed results are distinct logical aspects. The Machine implementation may hold all three; this view assigns each fact a provenance without claiming that the implementation already separates its storage.],
      [A node definition may be reused in many compositions. A Skill provides zero or more tool modules, and assembly selects zero or more Skills to create one orchestrator configuration.],
    )
    #info(title: "Grounding")[In the ETL example, the transition from validate on invalid is authored configuration. The current state validate is computed progress; the received invalid outcome is evidence interpreted through that configuration.]
  ])
  #section(title: "Definitions and values", lead: "Definitions are supplied by the consumer. Derived definitions are created by wrapping, schema conversion, or skill assembly before execution.", body: [
    #entity(title: "Node specification", description: [The configured operation reused at a composition position.], kind: "value-object", owner: "Consumer configuration", lifecycle: "immutable", domain: "composition", tint: "teal")[
      #attribute(name: "Name", type: "Node name", provenance: "authored")[The configured identifier; action and agent adapters may derive it from module metadata.]
      #attribute(name: "Description", type: "Human-readable operation description", provenance: "authored")[The description exposed to a parent and, when supported, a model tool.]
      #attribute(name: "Parameters", type: "Optional input schema", provenance: "authored")[The allowed input fields and constraints declared by the operation.]
      #attribute(name: "Configuration", type: "Node-kind options", provenance: "authored")[Execution mode, timeouts, child selection, and other options are specified in the execution chapter's adapter contracts.]
      #relates(cardinality: "n : 0..n")[A specification may contain child node specifications through parallel, traverse, or an agent composition.]
    ]
    #entity(title: "Composition definition", description: [The consumer's declared rules for selecting nodes and ending a run.], kind: "value-object", owner: "Consumer configuration", lifecycle: "immutable", domain: "composition", tint: "teal")[
      #attribute(name: "Workflow rules", type: "State bindings and transition map", provenance: "authored")[A workflow declares its initial state, node bindings, outcome-to-state map, terminal states, and success states.]
      #attribute(name: "Orchestrator rules", type: "Tool selection and generation configuration", provenance: "authored")[An orchestrator declares available operations, prompt, model, limits, and optional termination action.]
      #attribute(name: "Boundary rules", type: "Ambient key set and fork transformations", provenance: "authored")[These determine what input is ambient and how child ambient values are derived.]
      #relates(cardinality: "1 : 0..n")[A definition references configured node specifications.]
    ]
    #entity(title: "Context", description: [The current data value read by nodes and updated by the composition owner.], kind: "value-object", owner: "Parent strategy", lifecycle: "immutable", domain: "composition", tint: "teal")[
      #attribute(name: "Ambient values", type: "Read-only named values", provenance: "derived")[Extracted at start and derived at each child boundary from input and declared fork functions.]
      #attribute(name: "Working values", type: "Map of input and scoped result maps", provenance: "derived")[Computed at result acceptance from the previous context and the accepted result.]
      #attribute(name: "Fork transformations", type: "Named module-function-arguments tuples", provenance: "authored")[Each transformation takes ambient and working values and returns child ambient values.]
    ]
    #entity(title: "NodeIO", description: [The typed result value adapted by the composition layer.], kind: "value-object", owner: "Composition result adapter", lifecycle: "immutable", domain: "composition", tint: "teal")[
      #attribute(name: "Output", type: "Tagged map, text, or object", provenance: "observed")[The node or model supplies the value; accepting it is a separate composition decision.]
      #attribute(name: "Object schema", type: "Optional JSON Schema", provenance: "authored")[The schema associated with structured output, when one is provided.]
    ]
    #entity(title: "Skill", description: [A reusable capability definition independent of one execution.], kind: "value-object", owner: "Consumer skill registry", lifecycle: "immutable", domain: "composition", tint: "teal")[
      #attribute(name: "Name", type: "Unique skill name", provenance: "authored")[The registry selection identifier.]
      #attribute(name: "Description", type: "Capability description", provenance: "authored")[The information a caller or parent model uses to select the capability.]
      #attribute(name: "Prompt fragment", type: "Instruction text", provenance: "authored")[A self-contained fragment combined with the base prompt during assembly.]
      #relates(cardinality: "1 : 0..n")[A Skill provides action or agent modules adapted to node specifications.]
    ]
    #entity(title: "ApprovalRequest", description: [The immutable question and response constraints of one human-input attempt.], kind: "entity", owner: "Suspended strategy", lifecycle: "immutable", domain: "composition", tint: "teal")[
      #attribute(name: "Request ID", type: "Unique correlation identifier", provenance: "derived")[Generated when the request is constructed.]
      #attribute(name: "Question and visible data", type: "Prompt text and context subset", provenance: "derived")[Computed at request creation from the configured prompt and selected context keys.]
      #attribute(name: "Response constraints", type: "Allowed outcomes and optional data schema", provenance: "authored")[Declared on the HumanNode or approval policy.]
      #attribute(name: "Timeout policy", type: "Duration or infinity and timeout outcome", provenance: "authored")[The maximum wait and the outcome selected on expiry.]
      #attribute(name: "Creation time", type: "Instant", provenance: "observed")[The clock reading recorded when the request is created.]
      #attribute(name: "Flow location", type: "Agent identity and node or call location", provenance: "derived")[Enriched by the strategy with agent module, agent ID, node name, and workflow state or tool call.]
      #attribute(name: "Notification metadata", type: "Map of host-specific values", provenance: "authored")[Metadata for the external notification system.]
      #relates(cardinality: "1 : 0..n")[Candidate ApprovalResponses address this request; the owner accepts only a valid response while the request remains pending.]
    ]
    #entity(title: "ApprovalResponse", description: [The external response submitted for validation against one request.], kind: "event", owner: "Respondent and receiving strategy", lifecycle: "immutable", domain: "composition", tint: "teal")[
      #attribute(name: "Decision", type: "Outcome atom", provenance: "observed")[The submitted decision is not authority until the request owner validates it.]
      #attribute(name: "Data", type: "Optional response map", provenance: "observed")[Additional submitted values checked against the request's schema.]
      #attribute(name: "Respondent", type: "Opaque respondent identity", provenance: "observed")[Identity information supplied by the host; authentication is not defined by this record.]
      #attribute(name: "Comment", type: "Optional text", provenance: "observed")[The respondent's explanation.]
      #attribute(name: "Response time", type: "Instant", provenance: "observed")[The recorded response timestamp.]
      #relates(cardinality: "n : 1")[request_id addresses exactly one ApprovalRequest.]
    ]
  ])
  #section(title: "Execution census", lead: "Execution values track work under an agent identity. Their transitions are computed from configuration and accepted events.", body: [
    #entity(title: "Workflow run", description: [One workflow's progress and accepted result history.], kind: "aggregate", owner: "Workflow strategy", lifecycle: "stateful", domain: "composition", tint: "teal")[
      #attribute(name: "Current state", type: "Declared workflow state", provenance: "derived")[Computed at initialization and at every accepted transition.]
      #attribute(name: "Transition history", type: "Ordered state-outcome-time entries", provenance: "derived")[Appended at transition time; event timestamps come from observed clock values.]
      #attribute(name: "Original error", type: "Optional failure reason", provenance: "observed")[The original node, child, or transition failure retained for the caller.]
      #relates(cardinality: "n : 1")[Each run uses one Composition definition.]
      #relates(cardinality: "1 : 1")[Each run owns one current Context value.]
      #relates(cardinality: "1 : 0..n")[A run may track child references and branch executions; the Machine still has only one current state.]
    ]
    #entity(title: "Orchestration run", description: [One model-directed execution and its conversation and call progress.], kind: "aggregate", owner: "Orchestrator strategy", lifecycle: "stateful", domain: "composition", tint: "teal")[
      #attribute(name: "Status", type: "Orchestration lifecycle state", provenance: "derived")[Computed from model progress, active calls, held approvals, and suspended calls.]
      #attribute(name: "Iteration", type: "Nonnegative turn count", provenance: "derived")[Updated at model-turn boundaries and checked against the declared limit.]
      #attribute(name: "Conversation", type: "Ordered model and tool messages", provenance: "derived")[Constructed at each turn from observed responses and accepted tool results.]
      #attribute(name: "Final result", type: "Optional output or original error", provenance: "derived")[Selected at completion; structured successful results are wrapped as NodeIO objects.]
      #relates(cardinality: "n : 1")[The run uses one Composition definition's available tools and generation configuration.]
      #relates(cardinality: "1 : 1")[The run owns the Context used to construct tool arguments and accumulate accepted results.]
      #relates(cardinality: "1 : 0..n")[The run owns Tool calls, child references, and suspensions.]
    ]
    #entity(title: "Tool call", description: [One invocation selected by the model and tracked to resolution.], kind: "entity", owner: "Orchestrator strategy", lifecycle: "stateful", domain: "composition", tint: "teal")[
      #attribute(name: "Call ID", type: "Invocation identifier", provenance: "observed")[Received with the model's request and retained for result correlation.]
      #attribute(name: "Arguments", type: "Parsed parameter map", provenance: "observed")[Model-supplied arguments are checked and translated at the adapter boundary.]
      #attribute(name: "Progress", type: "Queued, held, executing, suspended, or resolved", provenance: "derived")[Computed from dispatch, approval, and result events.]
      #relates(cardinality: "n : 1")[A regular call names one available node specification.]
      #relates(cardinality: "1 : 0..1")[A held call has one current ApprovalRequest.]
      #relates(cardinality: "1 : 0..1")[A paused call has one current Suspension.]
    ]
    #entity(title: "Parallel execution", description: [The parent-owned collection state for FanOutNode or MapNode work.], kind: "entity", owner: "Parent strategy FanOut.State", lifecycle: "stateful", domain: "composition", tint: "teal")[
      #attribute(name: "Execution ID", type: "Unique parallel operation identifier", provenance: "derived")[Generated at dispatch for branch correlation.]
      #attribute(name: "Branch progress", type: "Queued, pending, completed, and suspended collections", provenance: "derived")[Updated when branches are dispatched, return, or resume.]
      #attribute(name: "Accepted results", type: "Named results or indexed results", provenance: "derived")[Collected at result acceptance; MapNode preserves input order.]
      #attribute(name: "Merge and failure policies", type: "Declared result and error policies", provenance: "authored")[FanOutNode supports default scoped deep merge or a custom function, and fail-fast or partial collection.]
      #relates(cardinality: "1 : 0..n")[A parallel execution invokes child node specifications; MapNode reuses one specification over the input collection.]
    ]
    #entity(title: "Suspension", description: [One paused computation tracked until continuation or expiry.], kind: "entity", owner: "Suspended strategy", lifecycle: "stateful", domain: "composition", tint: "teal")[
      #attribute(name: "Suspension ID", type: "Unique pause identifier", provenance: "derived")[Generated for correlation independently of any enclosing agent identity.]
      #attribute(name: "Reason", type: "Human input, rate limit, async completion, external job, or custom", provenance: "observed")[The node or policy supplies the pause reason.]
      #attribute(name: "Created at", type: "Instant", provenance: "observed")[Recorded at suspension creation.]
      #attribute(name: "Continuation policy", type: "Resume signal, duration or infinity, timeout outcome", provenance: "authored")[Declares the expected continuation and expiry policy.]
      #attribute(name: "Reason metadata", type: "Optional map", provenance: "observed")[Carries reason-specific information.]
      #attribute(name: "Pending membership", type: "Active or resolved", provenance: "derived")[Derived at read from the owner's pending state, not an added status field on the Suspension struct.]
      #relates(cardinality: "1 : 0..1")[A human-input suspension contains one ApprovalRequest; other reasons contain none.]
    ]
    #entity(title: "ChildRef", description: [The stable identity and lifecycle reference retained when a child process changes.], kind: "entity", owner: "Parent strategy Children collection", lifecycle: "stateful", domain: "composition", tint: "teal")[
      #attribute(name: "Child identity", type: "Agent module and agent ID", provenance: "derived")[Established at child creation or recovered from checkpoint metadata.]
      #attribute(name: "Tag", type: "Parent-assigned correlation value", provenance: "derived")[Derived from the parent state or tool call at dispatch.]
      #attribute(name: "Checkpoint key", type: "Optional storage address", provenance: "observed")[Recorded from the child's checkpoint notification.]
      #attribute(name: "Status", type: "Running, paused, hibernated, completed, or failed", provenance: "derived")[Updated from child lifecycle events.]
      #attribute(name: "Phase", type: "Spawning, awaiting result, or absent", provenance: "derived")[The phase determines whether replay re-spawns or keeps waiting.]
      #relates(cardinality: "n : 0..1")[A ChildRef may identify the Suspension that caused the child to pause.]
    ]
  ])
  #section(title: "Context and result transformations", lead: "The composition owner performs scoping and adaptation. Nodes return raw result values and do not add their own scope.", body: [
    #md-table(3, (
      [Operation], [Rule], [Concrete result],
      [Scope a workflow result], [Use the current state name], [extract returning records produces extract.records],
      [Scope an orchestrator result], [Use the tool name], [Repeated research results occupy research],
      [Merge nested maps], [Merge their entries recursively], [a.x and a.y both remain],
      [Merge non-map values], [Right-hand value replaces left], [items [2] replaces items [1]],
      [Flatten context], [Reserve the tuple ambient key], [Other top-level keys remain working data],
      [Fork for a child], [Transform ambient; copy working input], [A derived child trace ID does not replace the parent's],
    ))
    #info(title: "Grounding")[An extract result with records and count is stored as extract: (records: ..., count: 5). A downstream transform reads extract.records; a repeated extract may read its prior scope before returning an updated list.]
    #points(
      [Ambient keys are split from the initial input. The flattened ambient marker is the tuple returned by Context.ambient_key(), not a user string or atom.],
      [Fork functions receive ambient and working values and return transformed ambient values. They run at agent boundaries; ordinary parallel branches share ambient without an additional fork.],
      [A child returns only its result. The parent scopes that value in working context, so it cannot replace parent ambient context.],
    )
    #subsection(title: "Output adaptation")[
      The adapter makes heterogeneous node outputs acceptable to scoped map accumulation.
      #md-table(3, ([Input], [Map for accumulation], [Consumer result], [NodeIO map], [Underlying map], [Underlying map], [NodeIO text], [text: value], [Text], [NodeIO object], [object: value], [Object], [Bare string], [text: value], [String], [Other term], [value: term], [Original term where the public API permits]))
      #points([Machine.resolve_result handles envelopes, maps, strings, and the documented fallback for other terms. FanOut resolves each branch before merging; AgentTool unwraps for model serialization.], [Input and output type declarations may warn about incompatible adjacent nodes. They do not reject a composition whose runtime adapter can resolve the value.], [AgentNode.run wraps a child query result under result. The workflow synchronous child helper returns the raw child result; Machine adaptation therefore must also accept bare text.])
    ]
  ])
  #section(title: "Composition operations and algebra", lead: "Five constructors describe fixed composition structure. Model-selected invocation adds runtime selection of the next operation.", body: [
    #md-table(3, ([Operation], [Composition meaning], [Concrete carrier], [Sequence], [Run the next operation after the prior outcome], [Workflow transitions], [Parallel], [Run fixed named children and merge], [FanOutNode], [Choice], [Choose a declared outcome edge], [Transition lookup], [Traverse], [Apply one node to a runtime collection], [MapNode], [Identity], [Pass the input through], [Pass-through operation], [Bind], [Select the next invocation from runtime results], [Orchestrator]))
    #points(
      [Sequence can contain parallel work; parallel branches can contain sequences; traverse can contain agents, FanOutNode, or HumanNode. The same contract recurs at each level.],
      [FanOutNode selects a fixed set of different branches and returns a named map. MapNode selects one child specification, determines count from input, and returns an ordered list.],
      [The documented category-theory interpretation treats Context as one object, nodes as endomorphisms, error-aware composition as Kleisli composition, branching as coproduct selection, and parallel execution as a product.],
      [The interpretation treats the orchestrator as runtime path selection in the free category generated by available nodes, streaming as an unfolding computation, and nested agents as a functorial embedding. Ambient propagation corresponds to a Reader environment; fork transformations and NodeIO adaptation correspond to natural transformations.],
      [Suspension is described as a partial computation that completes after continuation. These interpretations explain intent; they are not a proof that arbitrary external effects obey the algebraic laws.],
    )
    #md-table(2, ([Proposed law from the source], [Required test or qualification], [Left and right identity], [Inserting a pass-through operation preserves the result under the chosen scoping convention], [Associative sequential composition], [Grouping pure compatible nodes does not alter outcomes or results], [Error as left zero], [Error short-circuits the chosen sequence], [Merge associativity and identity], [Specify the permitted result shapes and repeated-scope behavior], [Outcome preservation], [Composition preserves explicitly declared branching semantics], [Nested substitution], [Synchronous and directive paths preserve the same observable result contract], [Read-only environment], [Child execution leaves parent ambient values unchanged]))
  ])
  #section(title: "Lifecycles and decision rules", lead: "These machines describe lifecycle classes. Workflow-specific state names remain consumer data rather than a fixed universal enum.", body: [
    #subsection(title: "Workflow run lifecycle")[
      The run starts without active work and ends when a terminal state is reached.
      #state-machine(title: "Workflow run", accent: "teal", initial: "idle", accepting: ("success", "failure"), states: ("idle", "running", "waiting", "success", "failure"), transitions: (("idle", "running", "start"), ("running", "running", "nonterminal outcome"), ("running", "waiting", "child or suspension"), ("waiting", "running", "accepted result or resume"), ("running", "success", "success terminal"), ("running", "failure", "failure terminal or error"), ("waiting", "failure", "unrecoverable failure")), caption: [A suspended run retains its current Machine state. A rejected approval is a declared decision outcome; it can select any configured edge, not necessarily failure.])
      #points([Transition lookup uses exact state/outcome, wildcard state, wildcard outcome, then global wildcard. No match returns an error.], [Terminal states run no node. Defaults are done and failed, with done successful; overriding either terminal_states or success_states requires both, and success states must be a subset.])
    ]
    #pagebreak()
    #subsection(title: "Orchestration run lifecycle")[
      The run alternates model turns with call resolution.
      #state-machine(title: "Orchestration turn", accent: "teal", initial: "idle", accepting: ("completed", "error"), states: ("idle", "awaiting_llm", "resolving_calls", "completed", "error"), transitions: (("idle", "awaiting_llm", "query"), ("awaiting_llm", "resolving_calls", "tool calls"), ("resolving_calls", "awaiting_llm", "all resolved"), ("awaiting_llm", "completed", "final answer"), ("resolving_calls", "completed", "termination success"), ("awaiting_llm", "error", "generation or limit"), ("resolving_calls", "error", "abort")), caption: [resolving_calls abbreviates the precise awaiting states below; it is not a proposed runtime status.])
      #md-table(2, ([Runtime status], [Meaning], [awaiting_tools], [Executing or queued calls remain], [awaiting_approval], [Only gated decisions remain], [awaiting_tools_and_approval], [Running calls coexist with gated decisions], [awaiting_suspension], [Only suspended calls remain], [awaiting_tools_and_suspension], [Running calls coexist with suspended calls]))
      #points([StatusComputer derives the status from ToolConcurrency, ApprovalGate, and suspended_calls. In the observed implementation, approvals plus suspensions without executing calls produce awaiting_tools_and_approval; executing calls plus suspensions produce awaiting_tools_and_suspension even when approvals also remain. These labels do not expose every pending collection; the execution ledger retains the intended mixed-wait contract as an owner decision.], [Iteration limits are checked before termination-call interception. A final answer completes the run; a termination error is returned to the model so it can retry.])
    ]
    #pagebreak()
    #subsection(title: "Tool call lifecycle")[
      A call is held or queued before execution and resolves once its result has been accepted.
      #state-machine(title: "Tool call", accent: "teal", flow: "top-to-bottom", initial: "selected", accepting: ("resolved",), states: ("selected", "held", "queued", "executing", "suspended", "resolved"), transitions: (("selected", "held", "approval required"), ("selected", "queued", "allowed"), ("held", "queued", "approved"), ("held", "resolved", "rejected"), ("queued", "executing", "slot available"), ("executing", "resolved", "result or synthetic cancellation"), ("executing", "suspended", "pause"), ("suspended", "queued", "resume without data"), ("suspended", "resolved", "resume data or timeout")), caption: [Failure, rejection, and sibling cancellation can resolve calls with synthetic results. Abort ends the owning run rather than requiring a successful call result. Withdrawal of an accepted approval is not specified.])
    ]
    #pagebreak()
    #subsection(title: "Parallel execution lifecycle")[
      An empty operation completes without dispatch; otherwise it waits for every required branch to resolve.
      #state-machine(title: "Parallel execution", accent: "teal", initial: "created", accepting: ("completed", "failed"), states: ("created", "running", "waiting", "completed", "failed"), transitions: (("created", "completed", "empty collection"), ("created", "running", "dispatch"), ("running", "waiting", "only suspensions remain"), ("waiting", "running", "continuation"), ("running", "completed", "all results"), ("waiting", "completed", "last resumed result"), ("running", "failed", "fail-fast error")), caption: [Queued and executing branches are distinct collections. A custom FanOut merge controls result aggregation; MapNode returns results in input order.])
    ]
    #subsection(title: "Suspension lifecycle")[
      Pending membership records whether a pause can still consume a continuation.
      #state-machine(title: "Suspension", accent: "teal", initial: "absent", accepting: ("resolved",), states: ("absent", "pending", "resolved"), transitions: (("absent", "pending", "pause"), ("pending", "resolved", "validated resume"), ("pending", "resolved", "active timeout"), ("pending", "pending", "invalid response")), caption: [Once resolved, a late timeout cannot consume another transition. Cancellation and duplicate response behavior require the path-specific contracts in the execution chapter.])
    ]
    #pagebreak()
    #subsection(title: "Child reference lifecycle")[
      A parent tracks child progress separately from the process identifier used for transport.
      #state-machine(title: "ChildRef status", accent: "teal", initial: "running", accepting: ("completed", "failed"), states: ("running", "paused", "completed", "failed"), transitions: (("running", "paused", "checkpoint notification"), ("paused", "running", "restored child starts"), ("running", "completed", "normal exit"), ("running", "failed", "abnormal exit"), ("paused", "completed", "normal exit"), ("paused", "failed", "abnormal exit")), caption: [Children.record_result clears the communication phase without changing status. Children.record_exit marks normal exits completed and every other reason failed, including an exit recorded after pause. Hibernated remains a declared status without a distinct transition in these helpers; this observed lifecycle does not settle the intended checkpoint-exit policy.])
      #md-table(3, ([Communication phase], [Event or condition], [Result], [Absent], [Child dispatch], [spawning], [spawning], [Child-started confirmation], [awaiting_result], [awaiting_result], [Accepted child result], [Absent; status unchanged], [spawning], [Checkpoint replay], [Re-emit SpawnAgent], [awaiting_result], [Checkpoint replay], [No phase-owned replay; compatibility fallback can still apply]))
      #points([Phase is independent of status. A missing child reference is the vacant state before dispatch; the diagram does not invent a spawning status on ChildRef. The execution chapter specifies compatibility fallback when phase maps and ChildRef fields disagree.])
    ]
  ])
  #section(title: "Effects and decision inputs", lead: "An accepted event changes the owning execution value; runtime operations apply its external consequences.", body: [
    #md-table(3, ([Change], [New or queued work], [In-flight work], [Node configuration before query], [Uses rebuilt nodes and tools], [Mid-run reconfiguration is not specified], [Approval required], [Held call is not dispatched], [Ungated siblings may continue], [Approval rejection], [Rejected call becomes synthetic result], [Sibling policy continues, cancels, or aborts], [Suspension], [Continuation is held], [Independent siblings can finish], [Checkpoint], [Restored configuration is rebuilt], [Interrupted effects may be replayed], [Accepted approval withdrawn], [Unspecified], [Unspecified]))
    #md-table(3, ([Decision point], [Available inputs], [Decision], [Workflow transition], [Current state, outcome, transition map], [Next state or missing-transition error], [Approval partition], [Tool call, context, static metadata, policy], [Proceed, hold, or policy error], [Resume validation], [Pending ID, response constraints, submitted data], [Accept or validation error], [Model response], [Classified response and iteration count], [Complete, invoke, retry, or fail], [Branch completion], [Pending, queued, suspended, and completed collections], [Dispatch more, wait, merge, or fail]))
    #info(title: "Five-sentence onboarding test")[A consumer defines nodes and composition rules. A run carries context and uses those rules to select work. Each result updates only its assigned working scope. A suspended operation keeps its identity until a validated continuation resolves it. The runtime executes effects and returns evidence to the owning run.]
    #points([Plain-language retelling: a parent gives a task to a participant and waits for its answer. The participant may ask a person for input, but it cannot rewrite the parent's protected input.])
  ])
  #section(title: "End-to-end walkthrough", lead: "The ETL example grounds configuration, result scoping, and outcome selection in one run.", body: [
    #points([The consumer configures extract, transform, validate, load, and a rejection-handling state. The initial state is extract.], [Extract returns records. The owner stores the result under extract, then follows the ok edge to transform.], [Validate returns invalid. The declared invalid edge selects the rejection-handling node rather than treating invalid as a transport failure.], [The run reaches done and exposes accumulated context. If a node fails, its original reason follows the configured error edge or becomes a missing-transition error.])
  ])
]
