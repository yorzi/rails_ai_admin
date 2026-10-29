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
These capabilities still
require host-specific validation. Field-grant snapshots do not substitute for
action/scope checks or constitute an AI exposure report.

Not implemented in this slice: associations, nested attributes, uploads/private
attachments, imports/exports, batch actions, metrics dashboards, saved views,
collection/global custom operations, custom CRUD handler replacement, asynchronous
business execution, general reconciliation UI, assistant installation,
Chat, provider calls, Surface dispatch and continuation. ActionPolicy integration
and advanced field plugins remain future work. Host-owned Devise authentication
is demonstrated in a packaged consumer; the engine does not provide accounts or
login routes.

Fixed selections persist only owner/contract/count/digest/expiry and target
ID/version/position metadata. They do not persist queries, labels or business
payload, create OperationRun/audit/job records, approve an operation or implement
collection admission/execution. They are a prerequisite for the planned
asynchronous batch workflows, not a narrowed replacement for that scope. See
[Fixed Selections]({% link _core_features/selections.md %}) for current boundaries.

Durable Work delivers one declared effect for an already committed operation.
The host must schedule scans, rebuild current authority and verify the actual
downstream idempotency/unknown-outcome protocol. It does not prove downstream
exactly-once behavior or complete the asynchronous-workflow roadmap.

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
