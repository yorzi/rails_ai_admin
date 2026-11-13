---
layout: default
title: API Reference
nav_order: 1
guide: false
description: Find generated Ruby API documentation and documented host entry points.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

The [RDoc reference]({{ '/api/' | relative_url }}) opens on `RailsAiAdmin` and has
[Markdown class pages]({{ '/api/index.md' | relative_url }}).

| Task | Public entry point |
| --- | --- |
| Configure host adapters | `RailsAiAdmin.configure`, `Configuration` |
| Build host-owned pages/statuses | `CustomController`, `Presentation::Status` |
| Carry authenticated authority | `Context` |
| Declare exposure | `Resource`, `Field`, `Registry` |
| Inspect schema-only suggestions | `SchemaSuggestions` (no registration or exposure) |
| Check host policy | `Authorization::Adapter`, `Authorization::PunditAdapter`, `Authorization::Access` |
| Coerce input | `InputSchema` |
| Reopen an eligible generic UI form | `Operations::Runner#resume_form`, `Operations::Runner::FormSession` |
| Declare/execute synchronous member operations | `Operation`, `Operations::Registry`, `Operations::Runner`, `Operations::Result` |
| Persist/deliver post-commit intent | `Work`, `Outbox::Writer`, `Outbox::Dispatcher`, `Outbox::DeliveryContext`, `Outbox::RequestDigest` |
| Bound a list query | `Queries::List` |
| Offer granted list tabs | `Resource.scopes`, `Queries::NamedScope` |
| Filter lists by typed values | `Field#filter_operators`, `Queries::List` (`filters:`) |
| Configure index tables | `Resource.index`, `Presentation::IndexSettings` |
| Review intents in a Surface (opt-in) | `config.surfaces`, `Resource.operation(surface:)`, `Integrations::ToolViews` |
| Normalize non-authoritative return hints | `Navigation::ListState` |
| Group authorized resource menus | `Resource.navigation`, `Navigation::Settings`, `Navigation::Menu` |
| Capture/revalidate fixed targets | `Selections::Builder`, `Selections::Builder::Snapshot`, `Selections::Builder::Target` |
| Review/admit/cancel collection operations | `Collections::Runner`, `Collections::Runner::Proposal`, `Collections::Result` |
| Recover admitted collection items | `Collections::Dispatcher` |
| Read current collection job receipts | `Collections::Queries` |
| Opt in to admin Chat or MCP | `config.assistant`, `config.mcp`, `Resource.assistant_changes` |
| Verify host boundaries | `TestKit`, `Doctor` |

Use [Configuration]({% link _getting_started/configuration.md %}) and
[Operations]({% link _core_features/operations.md %}) for host contracts.
[Admin Assistant]({% link _advanced/admin-assistant.md %}) and
[MCP Server]({% link _advanced/mcp-server.md %}) document the optional
integrations and their supported entry points.
[Fixed Selections]({% link _core_features/selections.md %}) documents the metadata-only
manifest contract; capture is not approval or collection execution.
[Collection Operations]({% link _core_features/collection-operations.md %}) documents
separate parent approval and durable per-record execution. Its server-created
lease claims and the shared Runner worker entry are internal execution authority,
not client-supplied confirmation APIs.

Regenerate the reference with `docs/site/bin/build-api.sh tmp/api`; do not edit
its generated HTML/Markdown.
