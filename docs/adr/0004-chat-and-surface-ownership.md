# ADR 0004: Defer assistant execution until coexistence is proved

Status: design boundary only; assistant is not implemented.

Future Chat/Message models belong to `RailsAiAdmin::Assistant` with
engine-specific tables. ToolCall and Usage rows use RubyLLM's own shared
`ruby_llm_tool_calls` and `ruby_llm_usages` tables. Provider configuration must use
released `RubyLLM.context` APIs and cannot alter product settings. Surface ownership
uses typed `raa:` refs and `raa_` component names. The released component-key
grammar rejects dots, as already specified in plan §6.3.1. Never overwrite the
host's rails_tool_views resolver, registry, controller, adapter or auto-delivery
settings.

The released rails_tool_views configuration is process-wide. Shared-host routing
and continuation are unresolved until SPIKE-03/06 passes. Conventional mode does
not configure it. No remembered or tool-wide approval can authorize business writes.
Paid providers, arbitrary SQL/code, assistant tables and Surface write routes are
not enabled in the foundation slice.

Tool-call and usage isolation is row-level, not table-level (revised 2026-10-30).
RubyLLM owns its supporting tables and applications own chats and messages, so its
message macro has no `tool_call_class` option and none will be proposed upstream.
The associations are polymorphic. Chat-level lookups, including pending approvals,
filter by the message class's `polymorphic_name` and the chat's own message ids;
`tool_call_id` is globally unique and reassigned on collision. A probe in
RubyLLM's dummy app with admin and product chat/message pairs sharing the same ids
showed separate tool calls, pending approvals and usages, rejected a cross-chat
`approve`, and kept one chat's rows when the other was destroyed. Admin code reads
ToolCall/Usage only through its own Chat/Message associations, never through
table-wide queries, global table overrides or private monkey patches. The usage
ledger is shared, so the admin chooses its usage owner deliberately to keep admin
spend out of product owner totals. See `docs/reference/dependency-contracts.md`.
