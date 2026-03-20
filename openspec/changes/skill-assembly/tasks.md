## 1. Test Support Setup

- [ ] 1.1 Add test skill fixtures to `test/support/test_skills.ex` — define reusable Skill structs for tests: `math_skill` (AddAction, MultiplyAction), `echo_skill` (EchoAction), `pipeline_skill` (TestWorkflowAgent)

## 2. Skill Struct — Tests First

- [ ] 2.1 Write `test/jido/composer/skill_test.exs` — struct creation (all fields, missing fields raise), enforce_keys validation
- [ ] 2.2 Write `test/jido/composer/skill_test.exs` — `assemble/2` tests: single skill, multiple skills, prompt composition format, tool deduplication, agent module as tool, empty skills list, assembly options pass-through (max_iterations, temperature)
- [ ] 2.3 Implement `lib/jido/composer/skill.ex` — Skill struct defstruct with @enforce_keys, `assemble/2` function (prompt composition, tool union, BaseOrchestrator.new + configure)
- [ ] 2.4 Implement `lib/jido/composer/skill/base_orchestrator.ex` — internal Orchestrator module used by `assemble/2` (minimal DSL definition with empty defaults)
- [ ] 2.5 Verify Skill tests pass — `mix test test/jido/composer/skill_test.exs`

## 3. DynamicAgentNode — Tests First

- [ ] 3.1 Write `test/jido/composer/node/dynamic_agent_node_test.exs` — struct creation, name/1, description/1, schema/1, to_tool_spec/1 (parameter_schema structure)
- [ ] 3.2 Write `test/jido/composer/node/dynamic_agent_node_test.exs` — run/3 tests using LLMStub: successful run with action-only skills, unknown skill name error, multiple skills combine tools
- [ ] 3.3 Implement `lib/jido/composer/node/dynamic_agent_node.ex` — DynamicAgentNode struct, Node behaviour callbacks (run/3, name/1, description/1, schema/1, to_tool_spec/1)
- [ ] 3.4 Verify DynamicAgentNode tests pass — `mix test test/jido/composer/node/dynamic_agent_node_test.exs`

## 4. AgentTool Integration

- [ ] 4.1 Write test in `test/jido/composer/orchestrator/agent_tool_test.exs` (or existing file) — `to_tool/1` with DynamicAgentNode produces valid ReqLLM.Tool
- [ ] 4.2 Update `lib/jido/composer/orchestrator/agent_tool.ex` — add clause to handle DynamicAgentNode (or generic Node struct with to_tool_spec/1)
- [ ] 4.3 Verify AgentTool tests pass

## 5. E2e Cassette Test — Mixed Node Types

- [ ] 5.1 Write `test/e2e/skill_assembly_e2e_test.exs` — define parent Orchestrator with DynamicAgentNode tool; skill registry with "math" skill (AddAction, MultiplyAction) and "pipeline" skill (TestWorkflowAgent); test: LLM selects skills, sub-agent assembles, uses action tools, returns result through parent
- [ ] 5.2 Record cassettes — run `RECORD_CASSETTES=true mix test test/e2e/skill_assembly_e2e_test.exs` to capture real LLM interactions for the e2e scenario
- [ ] 5.3 Verify e2e tests pass in replay mode — `mix test test/e2e/skill_assembly_e2e_test.exs`

## 6. Quality Gate

- [ ] 6.1 Run `mix precommit` — full quality gate (format, docs, compile, lint, test)
- [ ] 6.2 Verify no warnings with `mix check` (compile with warnings-as-errors)
