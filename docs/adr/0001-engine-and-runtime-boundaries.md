# ADR 0001: Isolated engine and runtime boundaries

Status: implementation decision, owner review pending.

Use `RailsAiAdmin`, matching Rails camelization, and no AI acronym inflection.
Host extensions live in `app/rails_ai_admin/` as top-level `CustomerAdmin` classes.
Only configured string class names enter the registry. Rebuild it in `to_prepare`.
No global patches to host controllers, models, parameter filtering or providers.

Ship one gem with explicit bounded Rails, rails_tool_views and RubyLLM dependencies.
Do not require experimental adapters or provision AI tables during normal install.
Keep assistant storage separate from product Chat/Message tables. The future
Assistant integration must verify released APIs and cannot use RubyLLM main APIs.

Prebuilt, namespaced assets are supplied as CSS and ESM. Host assets are unchanged.
The first slice has no external side effects or asynchronous domain operations.
SPIKE-01/07 evidence must identify host, database and asset pipeline separately.
