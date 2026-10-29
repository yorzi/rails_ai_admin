---
layout: default
title: Data and Security
nav_order: 2
description: Protect execution evidence and understand the host responsibilities that remain.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* What the engine stores in intents and audits.
* How request redaction and frontend assets are scoped.
* Where callback, log and extension trust boundaries end.

## Keep Execution Evidence Minimal

`rails_ai_admin_operation_runs` stores server intent identity, ownership, operation
version, canonical digest, record refs, approval evidence, expiry, status, audit ref
and callback warning. It does not store full submitted payloads or record snapshots.
`rails_ai_admin_audit_events` records actor/tenant refs, operation/result codes,
record/correlation refs and changed field names. Arbitrary model validation messages
are not returned as errors because they may contain confidential values.

Audit model instances are append-only through the normal Active Record model API.
Direct SQL and database administrators remain outside that boundary. Framework
audits cover writes through its runner, not all changes made by the host elsewhere.
There is no retention/purge scheduler or Audit Explorer in the initial slice.

## Redact Requests Without Changing Host Filters

The named engine mount gets request-local filtering before Rails logs the initial
URL, plus controller-local filtering for arbitrary payload values. The host's
global `filter_parameters` list is not changed. Responses use `no-store` and private
cache directives. Actor/tenant/security context is rebuilt for each request.

Host SQL debug logs, custom loggers and instrumentation may still contain domain
values. Configure production log levels and host redaction deliberately. Do not
expose password/token/credential fields as ordinary admin data. A framework filter
cannot erase data already saved by another logger, provider or downloaded copy.

## Serve Prebuilt Assets Under a Strict Policy

The gem includes namespaced CSS and a bundled ESM entry point with Turbo and
Stimulus. Installation does not require host Node, Tailwind, importmap or a JS
bundling tool to compile admin sources. The admin has its own document/layout;
it does not inject its CSS or Stimulus application into ordinary host pages.

The controller supplies a per-response nonce and `csp-nonce` meta tag for Turbo's
injected stylesheet. The policy keeps scripts on the same origin and does not add
`unsafe-inline`. Static assets must still be served by the host's configured asset
pipeline. Presence of build artifacts alone does not prove every Propshaft,
Sprockets or strict-CSP browser combination works; see executed compatibility evidence.

## Treat Host Ruby as Trusted Code

Templates, model callbacks and policy adapters are trusted Ruby. They can bypass
framework boundaries; this gem does not sandbox them. Generic writes require
callbacks without irreversible external effects. A callback warning after commit
must be reconciled rather than treated as an uncommitted failure.

The current engine does not expose assistant tools, arbitrary SQL, private uploads,
exports, cross-database writes or asynchronous business actions. Each needs its
own later contract and adversarial validation before becoming a supported feature.

## Next Steps

* [Operations]({% link _core_features/operations.md %}) explains committed outcomes and retries.
* [Dependency Contracts]({% link _reference/dependency-contracts.md %}) distinguishes constraints from dependency defects.
