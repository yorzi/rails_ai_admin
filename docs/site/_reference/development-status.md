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
policy contracts, independent field grants, readonly resources, scalar forms,
bounded search/sort/pagination, typed inputs, optimistic locking, server-issued
intents, atomic receipt/audit writes, install/resource generators, doctor and an
initial TestKit. These capabilities still require host-specific validation.

Not implemented in this slice: associations, nested attributes, uploads/private
attachments, imports/exports, batch actions, metrics dashboards, saved views,
custom operation handlers, durable background operations, assistant installation,
Chat, provider calls, Surface dispatch and continuation. Pundit/ActionPolicy
integration and advanced field plugins are future work.

The checkout's `COMPATIBILITY.md` and `ROADMAP.md` identify executed evidence and
remaining milestones. In-repository tests, packaged-consumer tests, actual browser
checks, paid providers, human usability work and independent security review are
different evidence. Do not substitute one for another.

Release gates A through E remain required, including two independent packaged
hosts, real provider validation with an approved budget, migration samples and
explicit owner release approval. No remote deployment or gem publication is
performed by the current local build commands.
