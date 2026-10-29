---
layout: default
title: API Reference
nav_order: 1
guide: false
description: Read generated Ruby API documentation for the development implementation.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

The [RDoc reference]({{ '/api/' | relative_url }}) opens on `RailsAiAdmin` and has
[Markdown class pages]({{ '/api/index.md' | relative_url }}).

| Task | Public entry point |
| --- | --- |
| Configure host adapters | `RailsAiAdmin.configure`, `Configuration` |
| Carry authenticated authority | `Context` |
| Declare exposure | `Resource`, `Field`, `Registry` |
| Inspect schema-only suggestions | `SchemaSuggestions` (no registration or exposure) |
| Check host policy | `Authorization::Adapter`, `Authorization::PunditAdapter`, `Authorization::Access` |
| Coerce input | `InputSchema` |
| Declare/execute member operations | `Operation`, `Operations::Registry`, `Operations::Runner`, `Operations::Result` |
| Persist/deliver post-commit intent | `Work`, `Outbox::Writer`, `Outbox::Dispatcher`, `Outbox::DeliveryContext`, `Outbox::RequestDigest` |
| Bound a list query | `Queries::List` |
| Capture/revalidate fixed targets | `Selections::Builder`, `Selections::Builder::Snapshot`, `Selections::Builder::Target` |
| Verify host boundaries | `TestKit`, `Doctor` |

Only documented, tested APIs are current. Pseudocode in the development plan is
not an implemented public contract. Collection/global handlers, custom CRUD overrides and Assistant APIs remain
unavailable. Start with [Configuration]({% link _getting_started/configuration.md %})
and [Operations]({% link _core_features/operations.md %}) before invoking the Ruby API.
[Fixed Selections]({% link _core_features/selections.md %}) documents the metadata-only
manifest contract; capture is not approval or collection execution.

Regenerate the reference with `docs/site/bin/build-api.sh tmp/api`; do not edit
its generated HTML/Markdown.
