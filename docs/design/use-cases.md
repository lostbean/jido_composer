# Use Cases

Concrete scenarios showing how Jido Composer's two patterns combine to build
diverse agentic systems. Each use case demonstrates a different point on the
[control spectrum](interface.md#control-spectrum) — from fully deterministic to
fully adaptive, and the interesting mixed configurations in between.

---

## 1. Deterministic ETL Pipeline

**Pattern**: Workflow only, all ActionNodes.

**Scenario**: Extract data from an API, transform it, validate the schema, load
into a data store. Every step is predetermined; no runtime decisions needed.

```mermaid
stateDiagram-v2
    [*] --> extract
    extract --> transform : ok
    transform --> validate : ok
    validate --> load : ok
    validate --> quarantine : invalid
    load --> done : ok
    quarantine --> done : ok
    done --> [*]
    extract --> failed : error
    transform --> failed : error
    load --> failed : error
    failed --> [*]
```

**DSL shape**:

```
use Jido.Composer.Workflow,
  name: "etl_pipeline",
  description: "Extract, transform, validate, and load data",
  nodes: %{
    extract:    ExtractFromAPI,
    transform:  NormalizeSchema,
    validate:   ValidateRecords,
    load:       WriteToStore,
    quarantine: QuarantineBadRecords
  },
  transitions: %{
    {:extract, :ok}       => :transform,
    {:transform, :ok}     => :validate,
    {:validate, :ok}      => :load,
    {:validate, :invalid} => :quarantine,
    {:load, :ok}          => :done,
    {:quarantine, :ok}    => :done,
    {:_, :error}          => :failed
  },
  initial: :extract
```

**Why Workflow**: The pipeline is fixed. There is no decision about _what_ to do
next — only _whether_ the data is valid. The `:invalid` outcome branch handles
the one conditional case.

---

## 2. LLM Research Coordinator

**Pattern**: Orchestrator only, mixed ActionNodes and AgentNodes.

**Scenario**: A user asks a research question. The LLM decides whether to search
the web, query a database, read documents, or synthesize an answer. It may use
multiple tools in sequence before producing a final response.

```mermaid
graph TB
    ORC["Research Coordinator<br/>(Orchestrator)"]
    S["WebSearchAction"]
    D["DatabaseQueryAction"]
    R["DocumentReaderAction"]
    W["SummaryWriterAction"]

    ORC -->|"LLM chooses"| S
    ORC -->|"LLM chooses"| D
    ORC -->|"LLM chooses"| R
    ORC -->|"LLM chooses"| W
```

**DSL shape**:

```
use Jido.Composer.Orchestrator,
  name: "research_coordinator",
  description: "Research any topic using available tools",
  model: "anthropic:claude-sonnet-4-20250514",
  nodes: [
    WebSearchAction,
    DatabaseQueryAction,
    DocumentReaderAction,
    SummaryWriterAction
  ],
  system_prompt: "You are a research assistant. Use the available tools to
    gather information, then synthesize a comprehensive answer.",
  max_iterations: 10
```

**Why Orchestrator**: The research path is unpredictable. The LLM must decide
which sources to consult, how many queries to run, and when it has enough
information to answer.

---

## 3. Orchestrator Wrapping Workflows

**Pattern**: Orchestrator at the top, Workflows as tools.

**Scenario**: A project management assistant can run several deterministic
pipelines — onboarding, deployment, reporting — and the LLM decides which
pipeline to trigger based on the user's request.

```mermaid
graph TB
    ORC["Project Manager<br/>(Orchestrator)"]

    subgraph "Onboarding Pipeline"
        O1["create_account"] --> O2["provision"] --> O3["notify"]
    end

    subgraph "Deploy Pipeline"
        D1["build"] --> D2["test"] --> D3["deploy"] --> D4["verify"]
    end

    subgraph "Report Pipeline"
        R1["gather_metrics"] --> R2["analyze"] --> R3["format_report"]
    end

    ORC -->|"tool: run_onboarding"| O1
    ORC -->|"tool: run_deploy"| D1
    ORC -->|"tool: run_report"| R1
    ORC -->|"tool: direct action"| SA["SlackNotifyAction"]
```

**DSL shape**:

```
# Three deterministic workflows
use Jido.Composer.Workflow,
  name: "onboarding",
  description: "Onboard a new team member: create account, provision access, notify team",
  nodes: %{...}, transitions: %{...}, initial: :create_account

use Jido.Composer.Workflow,
  name: "deploy",
  description: "Build, test, deploy, and verify a release",
  nodes: %{...}, transitions: %{...}, initial: :build

use Jido.Composer.Workflow,
  name: "report",
  description: "Gather metrics, analyze trends, produce formatted report",
  nodes: %{...}, transitions: %{...}, initial: :gather_metrics

# Orchestrator that can invoke any of them
use Jido.Composer.Orchestrator,
  name: "project_manager",
  description: "Project management assistant",
  model: "anthropic:claude-sonnet-4-20250514",
  nodes: [
    {OnboardingWorkflow, description: "Onboard a new team member", mode: :sync},
    {DeployWorkflow, description: "Deploy a release", mode: :sync},
    {ReportWorkflow, description: "Generate a project report", mode: :sync},
    SlackNotifyAction
  ],
  system_prompt: "You manage project operations. Choose the right pipeline
    for the user's request. You can also send Slack messages directly."
```

**Why this mix**: The individual pipelines are deterministic and well-tested.
The LLM adds the intelligence layer of understanding _which_ pipeline to run
and _when_, plus the ability to combine pipelines or take direct actions.

---

## 4. Workflow Wrapping an Orchestrator

**Pattern**: Workflow at the top, Orchestrator at a decision point.

**Scenario**: A content publishing pipeline that is mostly deterministic
(fetch content, publish, distribute), but has one step — editorial review —
where an LLM must decide whether to approve, request revisions, or reject.

```mermaid
stateDiagram-v2
    [*] --> fetch_content
    fetch_content --> editorial_review : ok
    editorial_review --> publish : approved
    editorial_review --> request_revision : needs_revision
    editorial_review --> reject : rejected
    publish --> distribute : ok
    distribute --> done : ok
    request_revision --> done : ok
    reject --> done : ok
    done --> [*]
    fetch_content --> failed : error
    publish --> failed : error
    distribute --> failed : error
    failed --> [*]
```

**DSL shape**:

```
# The adaptive step
use Jido.Composer.Orchestrator,
  name: "editorial_review",
  description: "Review content for quality, accuracy, and style",
  model: "anthropic:claude-sonnet-4-20250514",
  nodes: [
    CheckFactsAction,
    CheckStyleAction,
    CheckComplianceAction
  ],
  system_prompt: "Review the submitted content. Use the available tools to
    check facts, style, and compliance. Return a final verdict:
    approved, needs_revision, or rejected."

# The deterministic pipeline that uses it
use Jido.Composer.Workflow,
  name: "content_publisher",
  description: "End-to-end content publishing pipeline",
  nodes: %{
    fetch_content:    FetchContentAction,
    editorial_review: {EditorialReviewOrchestrator, mode: :sync},
    publish:          PublishAction,
    distribute:       DistributeAction,
    request_revision: NotifyAuthorAction,
    reject:           ArchiveRejectedAction
  },
  transitions: %{
    {:fetch_content, :ok}          => :editorial_review,
    {:editorial_review, :approved} => :publish,
    {:editorial_review, :needs_revision} => :request_revision,
    {:editorial_review, :rejected} => :reject,
    {:publish, :ok}                => :distribute,
    {:distribute, :ok}             => :done,
    {:request_revision, :ok}       => :done,
    {:reject, :ok}                 => :done,
    {:_, :error}                   => :failed
  },
  initial: :fetch_content
```

**Why this mix**: Most of the pipeline is mechanical. Only the editorial review
requires judgment. By isolating the LLM to a single Workflow state, the system
remains predictable and auditable while benefiting from adaptive intelligence
exactly where it is needed.

---

## 5. Multi-Level Nesting

**Pattern**: Three levels deep — Orchestrator → Workflow → Orchestrator.

**Scenario**: A customer support system. The top-level Orchestrator triages
incoming requests. It dispatches to specialized Workflows (billing, technical,
account). The technical support Workflow has an adaptive diagnostic step that
uses its own Orchestrator to investigate issues.

```mermaid
graph TB
    L1["Support Triage<br/>(Orchestrator)"]

    subgraph "Billing Workflow"
        B1["lookup_account"] --> B2["check_charges"] --> B3["resolve"]
    end

    subgraph "Technical Workflow"
        T1["gather_logs"]
        T2["diagnose<br/>(Orchestrator)"]
        T3["apply_fix"]
        T4["verify"]
        T1 --> T2 --> T3 --> T4
    end

    subgraph "Account Workflow"
        A1["verify_identity"] --> A2["update_account"]
    end

    L1 -->|"billing issue"| B1
    L1 -->|"technical issue"| T1
    L1 -->|"account issue"| A1
```

**Why three levels**: Each level operates at a different granularity of decision
making. The triage Orchestrator makes a broad routing decision. The Workflow
provides a structured process. The inner diagnostic Orchestrator has the
flexibility to investigate with various tools before recommending a fix.

---

## 6. Workflow with Parallel Sub-Agents

**Pattern**: Workflow with a [FanOutNode](nodes/README.md#fanoutnode) at one
state.

**Scenario**: A due diligence check that runs financial analysis, legal review,
and background check in parallel, then merges results for a final decision.

The Workflow [Machine](workflow/state-machine.md) has a single `status` field —
two nodes cannot execute simultaneously within the FSM. FanOutNode solves this
by encapsulating parallel execution behind the standard Node interface: it
appears as a single state to the FSM but internally spawns all branches
concurrently and merges their results.

```mermaid
stateDiagram-v2
    [*] --> gather_data
    gather_data --> parallel_review : ok
    parallel_review --> decision : ok
    decision --> approve : pass
    decision --> flag : concerns
    approve --> done : ok
    flag --> done : ok
    done --> [*]
    gather_data --> failed : error
    parallel_review --> failed : error
    decision --> failed : error
    failed --> [*]
```

**DSL shape**:

```
# Each review is its own Workflow or Orchestrator
use Jido.Composer.Workflow,
  name: "financial_review", description: "Analyze financial health", ...
use Jido.Composer.Workflow,
  name: "legal_review", description: "Check legal standing", ...
use Jido.Composer.Orchestrator,
  name: "background_check", description: "Investigate background using public records", ...

# FanOutNode runs all three reviews concurrently
# Results are scoped under each branch's name and deep-merged
use Jido.Composer.Workflow,
  name: "due_diligence",
  description: "Complete due diligence assessment",
  nodes: %{
    gather_data: GatherDataAction,
    parallel_review: %FanOutNode{
      name: "parallel_review",
      branches: [
        AgentNode.new(FinancialReviewWorkflow, mode: :sync),
        AgentNode.new(LegalReviewWorkflow, mode: :sync),
        AgentNode.new(BackgroundCheckOrchestrator, mode: :sync)
      ],
      timeout: 60_000
    },
    decision: DecisionAction,
    approve:  ApproveAction,
    flag:     FlagForReviewAction
  },
  transitions: %{
    {:gather_data, :ok}     => :parallel_review,
    {:parallel_review, :ok} => :decision,
    {:decision, :pass}      => :approve,
    {:decision, :concerns}  => :flag,
    {:approve, :ok}         => :done,
    {:flag, :ok}            => :done,
    {:_, :error}            => :failed
  },
  initial: :gather_data
```

The `parallel_review` state's FanOutNode spawns all three review agents
concurrently. The merged result contains each branch's output scoped under its
name:

```
%{
  parallel_review: %{
    financial_review: %{score: 85, risk: :low},
    legal_review: %{status: :clear, notes: "..."},
    background_check: %{passed: true}
  }
}
```

The downstream `decision` node reads from these scoped keys to make its
determination.

---

## 7. Orchestrator Composing Orchestrators

**Pattern**: Multi-agent collaboration through nested Orchestrators.

**Scenario**: A product development assistant coordinates a researcher (who has
research tools), a designer (who has design tools), and an engineer (who has
coding tools). Each specialist is its own Orchestrator with domain-specific
tools.

```mermaid
graph TB
    COORD["Product Coordinator<br/>(Orchestrator)"]
    RES["Researcher<br/>(Orchestrator)"]
    DES["Designer<br/>(Orchestrator)"]
    ENG["Engineer<br/>(Orchestrator)"]

    COORD -->|"research task"| RES
    COORD -->|"design task"| DES
    COORD -->|"engineering task"| ENG

    RES --> RT1["WebSearchAction"]
    RES --> RT2["PaperSearchAction"]
    RES --> RT3["AnalyzeDataAction"]

    DES --> DT1["SketchAction"]
    DES --> DT2["MockupAction"]
    DES --> DT3["DesignReviewAction"]

    ENG --> ET1["CodeGenAction"]
    ENG --> ET2["TestRunAction"]
    ENG --> ET3["DeployAction"]
```

**Why nested Orchestrators**: Each specialist has its own tool set and system
prompt tuned for its domain. The coordinator does not need to understand all
tools — it delegates to specialists and synthesizes their results. This mirrors
how human teams work: a manager coordinates specialists without needing to
know the details of each specialty.

---

## 8. Dynamic Agent Assembly via Skills

**Pattern**: Orchestrator with a [DynamicAgentNode](skills/README.md#dynamicagentnode).

**Relationship to #7**: Use case #7 pre-defines each specialist as a module —
this works when the set of specialists is stable and bounded (researcher,
designer, engineer). Use case #8 assembles specialists at runtime from
capability bundles — this earns its indirection when the useful capability
combinations grow combinatorially and are determined by runtime context. See
[When to Use Skills vs. Pre-Defined Agents](skills/README.md#when-to-use-skills-vs-pre-defined-agents).

**Scenario**: A general-purpose assistant that creates specialized sub-agents on
demand. Instead of pre-defining every possible agent configuration, the
top-level Orchestrator delegates tasks to a DynamicAgentNode that assembles
purpose-built agents from [Skills](skills/README.md).

```mermaid
graph TB
    COORD["General Assistant<br/>(Orchestrator)"]
    DAN["DynamicAgentNode<br/>(delegate_task tool)"]

    subgraph "Skill Registry"
        S1["Web Search Skill<br/>prompt + SearchAction, FetchAction"]
        S2["Code Editing Skill<br/>prompt + ReadFileAction, EditFileAction, RunTestAction"]
        S3["Planning Skill<br/>prompt + OutlineAction, BreakdownAction"]
        S4["Data Analysis Skill<br/>prompt + QueryDBAction, AnalyticsWorkflow"]
    end

    subgraph "Assembled at Runtime"
        A1["Research Agent<br/>(web_search + planning skills)"]
        A2["Dev Agent<br/>(code_editing + web_search skills)"]
    end

    COORD -->|"delegate_task(skills: [web_search, planning])"| DAN
    DAN --> S1
    DAN --> S3
    DAN -->|"assembles"| A1

    COORD -->|"delegate_task(skills: [code_editing, web_search])"| DAN
    DAN --> S2
    DAN --> S1
    DAN -->|"assembles"| A2
```

**DSL shape**:

```
# Define skills as capability bundles
web_search = %Skill{
  name: "web_search",
  description: "Search the internet and fetch web pages",
  prompt_fragment: "You can search the web and retrieve page content.
    Use search for broad queries, fetch for specific URLs.",
  tools: [WebSearchAction, FetchPageAction]
}

data_analysis = %Skill{
  name: "data_analysis",
  description: "Query databases and run analysis pipelines",
  prompt_fragment: "You can query databases and run full analysis
    workflows including statistical analysis.",
  tools: [QueryDBAction, AnalyticsWorkflow]  # Workflow as a tool
}

# Top-level orchestrator with a DynamicAgentNode
use Jido.Composer.Orchestrator,
  name: "general_assistant",
  model: "anthropic:claude-sonnet-4-20250514",
  nodes: [
    %DynamicAgentNode{
      name: "delegate_task",
      description: "Delegate a task to a specialized sub-agent
        assembled from selected skills",
      skill_registry: [web_search, code_editing, planning, data_analysis],
      model: "anthropic:claude-sonnet-4-20250514",
      base_prompt: "You are a focused specialist. Complete the task
        using the tools available to you."
    },
    SummarizeAction  # Direct action for simple tasks
  ],
  system_prompt: "You are a general assistant. For complex tasks,
    delegate to a specialist by selecting the right skills.
    For simple tasks, handle them directly."
```

**Why Skills**: The number of possible capability combinations grows
combinatorially. Pre-defining an agent for every combination is impractical.
Skills let the parent LLM describe _what capabilities are needed_ and the
DynamicAgentNode handles the assembly. Note that `data_analysis` includes a
Workflow agent (`AnalyticsWorkflow`) as one of its tools — skill tools are
[Nodes](nodes/README.md), not just actions.

---

## Composition Patterns Summary

| Use Case             | Outer        | Inner                     | Determinism                            | Depth |
| -------------------- | ------------ | ------------------------- | -------------------------------------- | ----- |
| ETL Pipeline         | Workflow     | Actions                   | Fully deterministic                    | 1     |
| Research Coordinator | Orchestrator | Actions                   | Fully adaptive                         | 1     |
| Project Manager      | Orchestrator | Workflows + Actions       | Adaptive over deterministic            | 2     |
| Content Publisher    | Workflow     | Orchestrator + Actions    | Deterministic with adaptive step       | 2     |
| Customer Support     | Orchestrator | Workflows → Orchestrator  | Mixed, 3 levels                        | 3     |
| Due Diligence        | Workflow     | FanOutNode (parallel)     | Deterministic with parallel delegation | 2     |
| Product Development  | Orchestrator | Orchestrators             | Fully adaptive, multi-agent            | 2     |
| Dynamic Assembly     | Orchestrator | DynamicAgentNode + Skills | Adaptive with runtime-assembled agents | 2+    |

The common thread: the same [Node interface](nodes/README.md) and
[context flow model](nodes/context-flow.md) work at every level, regardless
of whether the composition is deterministic or adaptive, shallow or deeply
nested. See [Interface](interface.md) for the API design principles that make
this possible.
