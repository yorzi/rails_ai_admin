# ADR 0004: Defer assistant execution until coexistence is proved

Status: design boundary only; assistant is not implemented.

Future Chat/Message/ToolCall models belong to `RailsAiAdmin::Assistant` with
engine-specific tables. Provider configuration must use released `RubyLLM.context`
APIs and cannot alter product settings. Surface ownership uses typed `raa:` refs
and `raa.` component names. Never overwrite the host's rails_tool_views resolver,
registry, controller, adapter or auto-delivery settings.

The released rails_tool_views configuration is process-wide. Shared-host routing
and continuation are unresolved until SPIKE-03/06 passes. Conventional mode does
not configure it. No remembered or tool-wide approval can authorize business writes.
Paid providers, arbitrary SQL/code, assistant tables and Surface write routes are
not enabled in the foundation slice.
