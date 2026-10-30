---
layout: default
title: Development Status
nav_order: 5
guide: false
description: Read the supported development slice and the gates still required for release.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

The implementation starts with conventional scalar CRUD and a shared authorized
operation boundary. It is a development build, not a complete replacement for an
existing admin framework and not a production-readiness claim.

Current code includes explicit resources, fresh host contexts, custom default-deny
policy contracts and an optional Pundit adapter with an explicit policy per
resource, independent field grants, readonly resources, scalar forms,
bounded search/sort/pagination, typed inputs, optimistic locking, server-issued
intents, atomic receipt/audit writes, closed install/resource scaffolds, schema-only
commented field suggestions, diagnostic metadata and an initial TestKit with
anonymous-context and exact field-grant assertions. The code also implements
registered synchronous member operations, pure/input-bound confirmation, separate
operation-input/receipt/delivery grants and a typed durable outbox with stable
request binding, leases and bounded recovery. Fixed Selection manifests now
capture/revalidate up to 100 explicit canonical IDs and record versions through
separate default-deny selection permission and native no-JavaScript previews.
Collection operations now bind those manifests to one parent approval and
durable per-target child intents/items. A worker uses the shared Runner with fresh
authority, lease fencing and independent target transactions; native job receipts
and cancellation preserve committed results. These capabilities still require
host-specific validation. Field-grant snapshots do not substitute for
action/scope checks or constitute an AI exposure report. Registered scalar field
types now supply pure normalization/validation, constrained wire schemas and
field-level partials; [Field Types]({% link _core_features/field-types.md %})
documents this limited extension contract.
[Computed Fields]({% link _core_features/computed-fields.md %}) adds versioned
readonly scalar computations over explicit recursively granted dependencies, with
graph/snapshot/output/budget limits and per-record projection caching. It supplies
no virtual writes/search/sort or general model-method invocation.
[Template Overrides]({% link _advanced/template-overrides.md %}) now provides
allowlisted page/layout/partial copies with explicit context metadata and bounded
source/contract inspection. CURRENT metadata does not certify host edits.

Not implemented in this slice: associations, nested attributes, uploads/private
attachments, imports/exports, all-filtered or 10,000-target batch manifests,
metrics dashboards, saved views, global custom operations, custom CRUD handler
replacement, a full job center/retention workflow, general reconciliation UI,
assistant installation,
Chat, provider calls, Surface dispatch and continuation. ActionPolicy integration
and association/file/money field extensions remain future work. Host-owned Devise authentication
is demonstrated in a packaged consumer; the engine does not provide accounts or
login routes.

Fixed selections persist only owner/contract/count/digest/expiry and target
ID/version/position metadata. They do not persist queries, labels or business
payload. Capture itself creates no OperationRun/audit/job records and approves
no operation. The separate collection preflight persists bounded typed input on
a parent intent; human confirmation admits its exact targets, and each target
commits independently. Hosts must provide fresh job contexts, persistent queues
and recurring scans; automatic dispatch defaults to false. See
[Fixed Selections]({% link _core_features/selections.md %}) and
[Collection Operations]({% link _core_features/collection-operations.md %}). The
bounded implementation remains a prerequisite for the full planned batch workflow,
not a narrowed replacement for that scope.

Durable Work delivers one declared effect for an already committed operation.
The host must schedule scans, rebuild current authority and verify the actual
downstream idempotency/unknown-outcome protocol. It does not prove downstream
exactly-once behavior or complete the asynchronous-workflow roadmap. A collection
item can succeed while its separate Work remains pending or needs reconciliation.

The checkout's `COMPATIBILITY.md` and `ROADMAP.md` identify executed evidence and
remaining milestones. In-repository tests, packaged-consumer tests, actual browser
checks, paid providers, human usability work and independent security review are
different evidence. Do not substitute one for another.

The native-session SQLite consumer and independent Devise/Pundit/PostgreSQL support
consumer provide packaged integration evidence for this limited slice. Host B also
exercises actual Rails development reload and fresh-process crash/replay probes.
These author-controlled synthetic hosts do not establish independent usage, full
Admin P0 coverage or production readiness.

Release Gates A through E remain open, including completion of all required
packaged-host workflows, real provider validation with an approved budget, migration samples and
explicit owner release approval. No remote deployment or gem publication is
performed by the current local build commands.
