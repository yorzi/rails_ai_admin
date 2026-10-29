# Architecture

Status: foundation implementation; API may change before release.

The isolated `RailsAiAdmin::Engine` owns admin routes and execution evidence.
The host owns authentication, SQL policy scopes, domain models and services.
Resources explicitly declare exposed scalar fields. Field declarations never
widen a policy decision. No arbitrary constant, SQL or template comes from input.

A host context adapter returns a fresh `Context` for each request. References
include the `raa:` namespace, object type and key. There is no mutable global
Current context. Configuration stores host class names and freezes after boot;
Rails `to_prepare` replaces the entire resource registry after reload.

All writes must use the operation runner. Domain records, intents and audit events
must share the same Active Record connection pool. The first slice supports
synchronous database-only CRUD with `lock_version`. Cross-pool writes, callbacks
with external effects and custom operations are unsupported in this slice.

RubyLLM and rails_tool_views are bounded runtime dependencies. Conventional boot
must not load the experimental adapter, require AI tables or call a provider.
Chat/Surface integration remains a separate milestone, using the same authority.
See docs/adr and docs/reference/public-contract.md.
