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
intents, atomic receipt/audit writes, install/resource generators, doctor and an
initial TestKit. These capabilities still require host-specific validation.

Not implemented in this slice: associations, nested attributes, uploads/private
attachments, imports/exports, batch actions, metrics dashboards, saved views,
custom operation handlers, durable background operations, assistant installation,
Chat, provider calls, Surface dispatch and continuation. ActionPolicy integration
and advanced field plugins remain future work. Host-owned Devise authentication
is demonstrated in a packaged consumer; the engine does not provide accounts or
login routes.

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
