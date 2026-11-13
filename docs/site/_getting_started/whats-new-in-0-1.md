---
layout: default
title: What's New in 0.1
nav_order: 6
description: Explore the first Public Preview workflows and the limits to consider before adopting them.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* Which workflows the Public Preview covers.
* Which host decisions you need to make before granting access.
* Where the preview has limits.

## Manage records in Rails

Register the resources and fields you intend to expose. Connect your host's
sessions, tenant scopes and grants. The same audited operation boundary handles
native forms, member operations and changes confirmed through review Surfaces.

* [Resources and Fields]({% link _core_features/resources-and-fields.md %}) covers
  CRUD, validation and supported field types.
* [Associations]({% link _core_features/associations.md %}) covers reference
  pickers, child panels and editable many-to-many references.
* [CSV Export and Import]({% link _core_features/csv-export.md %}) and
  [Record History]({% link _core_features/record-history.md %}) cover data
  movement, record changes and the audit log.
* [Dashboard]({% link _core_features/dashboard.md %}) and
  [Collection Operations]({% link _core_features/collection-operations.md %})
  cover counts, trends and jobs over a fixed set of records.

## Enable Chat and MCP separately

The native admin works with AI disabled. Enable
[Admin Chat]({% link _advanced/admin-assistant.md %}) for grant-filtered reads,
streaming replies and proposals that a person can review in the admin. The
chat keeps the composer below the scrollable conversation and displays record
links and review cards alongside messages.
Enable the [MCP Server]({% link _advanced/mcp-server.md %}) to let external
clients use the same tools with personal access tokens. A proposal becomes a
write only after a person confirms it.

## Public Preview limits

* Ruby 3.3 or newer, Rails 8.0.5.2 or newer below 8.2, and SQLite or PostgreSQL.
  On Rails 8.1 use 8.1.4.1 or newer. Rails 8.0 requires `json` 2.x.
* Association sorting, polymorphic writes, nested child forms and dedicated
  attach/detach policies are open. Collection selections hold at most 100
  explicitly selected records.
* Chat has a per-person daily message limit. Token and cost budgets and
  automatic conversation retention are open. Live provider evidence covers an
  earlier build through OpenRouter. Native provider APIs and live failure
  recovery still need verification.
* English ships with the engine. Hosts supply translations for their locales.
  A human screen-reader pass is still open.
* Review template and migration changes before updating a development host.
  Public Preview contracts may change across 0.x versions.

Run the [demo]({% link _getting_started/demo.md %}) against sample data, or
follow [Getting Started]({% link _getting_started/getting-started.md %}) to
install the engine in a host app. See [Upgrading]({% link _reference/upgrading.md %})
for existing development installations.
