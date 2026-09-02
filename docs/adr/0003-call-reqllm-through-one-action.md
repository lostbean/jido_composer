# Call ReqLLM through one action boundary

<a id="adr-0003"></a>

- Migrated rationale from the existing Orchestrator and LLM Integration documents; this record is part of the unapproved migration draft.
- ReqLLM already abstracts provider generation and conversation formats.
- LLMAction therefore calls ReqLLM directly instead of introducing another facade or configurable LLM behavior.
- Orchestrator state carries the generation options passed to that boundary.
