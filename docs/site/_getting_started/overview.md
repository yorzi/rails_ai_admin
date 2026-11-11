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

## Separate Target APIs from Implemented APIs

The current development slice supplies scalar conventional CRUD, custom and
optional explicitly mapped Pundit policies, bounded index queries, server-issued
form intents, typed synchronous member operations, independent operation-input
and receipt grants, durable post-commit Work intent, execution/audit records,
install/resource generators and initial
host verification helpers. Schema field suggestions remain comments in an
unregistered readonly resource. Doctor and field-grant snapshots inspect
configuration/permissions; they do not prove authentication or AI-visible data.
An independent packaged Devise/Pundit/PostgreSQL host
exercises a different authentication, model, policy and asset configuration from
the native-session SQLite host. These are author-controlled synthetic consumers,
not independent users or production adoption.

It does not implement the full development plan. Associations, CSV, private files,
larger batch workflows, dashboards with metrics, saved views, global actions,
custom CRUD overrides, broader asynchronous business workflows, Chat and Surface workflows
remain later milestones. Work delivers a committed fact after the domain
transaction; it is not a parallel asynchronous business-operation path.

RubyLLM and `rails_tool_views` are optional. The gem does not depend on them: add
`ruby_llm` (>= 2.1.1, < 3) to turn on admin Chat and `rails_tool_views` (~> 1.0.2)
to turn on review Surfaces, and boot rejects a version outside those ranges.
Ordinary mode loads neither, installs no AI tables, configures no provider and
needs no model key.

Outbox delivery has its own fresh context/permission, record-version policy,
deadline, lease and receipt. It requires recurring host scans and real downstream
idempotency; a database row or an after-commit hook is not exactly-once proof.

The current collection path supports one fixed selection of at most 100 targets,
one parent approval and independently committed leased items, with native review,
job results and cancellation. It does not complete the broader batch roadmap.

## Next Steps

* [Resources and Fields]({% link _core_features/resources-and-fields.md %}) shows the supported DSL.
* [Durable Outbox]({% link _advanced/durable-outbox.md %}) explains post-commit effects and recovery.
* [Dependency Contracts]({% link _reference/dependency-contracts.md %}) records integration boundaries.
* [Development Status]({% link _reference/development-status.md %}) distinguishes implementation from release gates.
