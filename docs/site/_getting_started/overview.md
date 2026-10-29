---
layout: default
title: How Rails AI Admin Works
nav_order: 3
description: Understand the current ownership boundary from request to committed receipt.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* Which responsibilities stay in the host.
* How resources, policies and operations cooperate.
* Which target features remain unimplemented.

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

Ordinary create, update and delete forms call `Operations::Runner`. The runner
checks the current authority, input schema and expected record version, then
commits the domain change, human confirmation, operation receipt and audit in one
database transaction. The engine does not call `update_all` or `delete_all` for
generic domain CRUD.

Domain models, `OperationRun` and `AuditEvent` must share the same Active Record
connection pool. Matching database addresses alone is insufficient. A framework
savepoint can isolate an operation within a caller's transaction; a result inside
an outer transaction is not committed until that outer transaction commits.

## Separate Target APIs from Implemented APIs

The current development slice supplies scalar conventional CRUD, explicit policy
adapters, bounded index queries, server-issued form intents, execution/audit
records, install/resource generators and initial host verification helpers.

It does not implement the full development plan. Associations, CSV, private files,
batch operations, dashboards with metrics, saved views, asynchronous operations,
custom operation handlers, Chat and Surface workflows remain later milestones.

RubyLLM and `rails_tool_views` are installed bounded dependencies. Their presence
does not mean the admin has integrated their runtime features. Ordinary mode does
not install AI tables, configure providers or require a model key. There is no
`config.ai` API or assistant install generator in this slice.

## Next Steps

* [Resources and Fields]({% link _core_features/resources-and-fields.md %}) shows the supported DSL.
* [Dependency Contracts]({% link _reference/dependency-contracts.md %}) records integration boundaries.
* [Development Status]({% link _reference/development-status.md %}) distinguishes implementation from release gates.
