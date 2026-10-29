# ADR 0004: Defer assistant execution until coexistence is proved

Status: design boundary only; assistant is not implemented.

Future Chat/Message/ToolCall models belong to `RailsAiAdmin::Assistant` with
engine-specific tables. Provider configuration must use released `RubyLLM.context`
APIs and cannot alter product settings. Surface ownership uses typed `raa:` refs
and `raa_` component names. The released component-key grammar rejects dots,
as already specified in plan §6.3.1. Never overwrite the host's rails_tool_views resolver,
registry, controller, adapter or auto-delivery settings.

The released rails_tool_views configuration is process-wide. Shared-host routing
and continuation are unresolved until SPIKE-03/06 passes. Conventional mode does
not configure it. No remembered or tool-wide approval can authorize business writes.
Paid providers, arbitrary SQL/code, assistant tables and Surface write routes are
not enabled in the foundation slice.

Phase 1 source/public-reflection evidence found an unresolved design assumption:
RubyLLM 2.1.1 custom Chat/Message mappings still use shared SDK ToolCall/Usage
classes and tables. Its message macro has no `tool_call_class` option and pending
approvals directly query the SDK class. The Engine-owned ToolCall boundary above
remains required, but its implementation is not established. Resolve this through
supported APIs or a reviewed upstream extension before admin Chat, without global
table overrides/private monkey patches. See `docs/reference/dependency-contracts.md`.
