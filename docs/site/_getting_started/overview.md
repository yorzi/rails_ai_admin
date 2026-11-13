---
layout: default
title: How Rails AI Admin Works
nav_order: 4
description: Learn how resources, host policies, and reviewed operations connect your Rails app to the admin.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* Which responsibilities stay in the host.
* How resources, policies and operations cooperate.
* How to add AI assistance and background operations.

## Keep Authority in the Host

The host owns users, tenants, authentication and domain models. The isolated
`RailsAiAdmin::Engine` owns conventional admin pages and its execution evidence.
An explicit resource registry determines which host models can be addressed.
Model names supplied in a URL are never converted into arbitrary Ruby constants.

A fresh context identifies the actor, tenant and security version. The policy
returns the complete SQL relation, action decisions and field grants. The resource
DSL can narrow these grants; it cannot widen them. A title is shown only when its
field and read action are authorized, otherwise a safe record reference is used.

## Share One Write Boundary

Ordinary create/update/delete and registered member-operation forms call
`Operations::Runner`. The runner
checks the current authority, input schema and expected record version, then
commits the domain change, human confirmation, operation receipt, audit and any
outbox intent in one database transaction. The engine does not call `update_all` or `delete_all` for
generic domain CRUD.

Domain models, `OperationRun`, `AuditEvent` and `WorkItem` must share one Active Record
connection pool. Matching database addresses alone is insufficient. A framework
savepoint can isolate an operation within a caller's transaction; a result inside
an outer transaction is not committed until that outer transaction commits.

## Add AI to Your Admin

Enable the optional assistant to search and read records through the current
administrator's permissions. RubyLLM connects to the provider configured by your
host. Review Surfaces use rails_tool_views to display proposed changes and collect
human confirmation. The same policies apply when tools are accessed through MCP.

Start with [Admin Assistant]({% link _advanced/admin-assistant.md %}) for provider
setup and [Review Surfaces]({% link _advanced/review-surfaces.md %}) for confirmation.

## Run Work After a Change

Use [Durable Outbox]({% link _advanced/durable-outbox.md %}) for declared effects
after a committed change, such as delivery to another service. Your host supplies
recovery scheduling and downstream idempotency.

Use [Collection Operations]({% link _core_features/collection-operations.md %})
to apply an approved operation to a fixed selection of up to 100 records. Each
item commits independently. The job page reports results and supports cancellation.

Consult [Development Status]({% link _reference/development-status.md %}) for
supported workflows and remaining limitations.

## Next Steps

* [Resources and Fields]({% link _core_features/resources-and-fields.md %}) shows the supported DSL.
* [Durable Outbox]({% link _advanced/durable-outbox.md %}) explains post-commit effects and recovery.
* [Dependency Contracts]({% link _reference/dependency-contracts.md %}) records integration boundaries.
* [Development Status]({% link _reference/development-status.md %}) distinguishes implementation from release gates.
