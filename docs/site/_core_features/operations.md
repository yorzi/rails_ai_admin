---
layout: default
title: Operations
nav_order: 2
description: Execute conventional writes with bound intents and atomic receipts.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* How server-issued intents bind a human submission.
* How replay and optimistic locking protect a business write.
* How to distinguish a failed write from a post-commit callback warning.

## Let Forms Own Ordinary Confirmation

New/edit pages issue a server-owned form intent. A deliberate Save binds its
normalized input and consumes confirmation inside the write transaction. A delete
uses a separate confirmation page. Ordinary create/update does not add a redundant
approval dialog.

The runner is also a Ruby API for **trusted host adapters**. Given an authenticated
`context`, a registered `CustomerAdmin` and a scoped `customer`:

```ruby
runner = RailsAiAdmin::Operations::Runner.new
intent = runner.prepare(
  context: context,
  resource: CustomerAdmin,
  operation: :update,
  target_id: customer.id,
  expected_version: customer.lock_version,
  input: { "name" => "Reviewed name" }
)

result = runner.execute(
  context: context,
  intent_ref: intent.id,
  input: { "name" => "Reviewed name" },
  human_confirmed: true,
  origin: :ui
)
```

`human_confirmed` is evidence supplied by trusted request handling. Never expose
it as an assistant tool parameter or accept it as authority from an untrusted
client. `origin` is audit metadata; changing it grants no permission.

Omit `input` from `prepare` for an ordinary editable form intent. Supplying it
creates an input-bound proposal: changing the payload requires a new intent.
Preparation does not run a domain save, validation or callback. A preview does
not guarantee execution will succeed.

## Bind Every Retry to the Original Intent

The intent binds actor, tenant, security version, resource, operation/schema
version, target, expected record version, input digest and expiry. HTTP controllers
also bind it to the actual endpoint's resource, action and target. Clients cannot
create an intent by inventing an ID.

The executor locks the intent before the domain record, rechecks current policy
and fields, then saves domain data, audit, confirmation and receipt together. A
same-intent/same-input retry returns the existing receipt and a **current** readable
projection. It does not repeat callbacks. A same-intent/different-input committed
retry returns `IDEMPOTENCY_CONFLICT`. Separate deliberate intents do not deduplicate
merely because their input happens to match.

Replay remains subject to current authority. Revoked, expired and cross-tenant
requests do not regain access from an old receipt. A deleted-record receipt contains
no historical field snapshot and requires a fresh collection-level destroy grant.
The engine provides no purge job yet; retain replay evidence through the full
published retry window and do not recreate expired intents from client content.

Changing a resource's policy mapping changes the operation fingerprint. Existing
development form/proposal intents then return `APPROVAL_INVALIDATED`; reopen the
form and review its current permissions instead of reusing the old intent. The
fingerprint is not a substitute for current action and field authorization.

## Require a Shared Connection and Record Version

Generic writes require one primary key and standard `lock_version` optimistic
locking. Host domain models, `OperationRun` and `AuditEvent` must share the same
connection pool. Cross-pool writes, shards, composite keys and MySQL writes are
unsupported. A database-level rollback also rolls back the successful receipt and
audit. SQLite write contention can return a retryable `CONFLICT`; retry with the
same still-valid intent rather than issuing a second business operation.

Only synchronous database CRUD is supported. A host callback that sends mail,
charges money or performs an HTTP call is not made safe by wrapping `save!` in a
transaction. Keep such a resource readonly or redesign its host write boundary;
Outbox delivery and custom handlers are later work.

## Inspect Results Without Assuming Rollback

`Result` exposes `code`, `status`, `success?`, `retryable?`, `record_id`, `audit_ref`,
`values`, `errors`, `replayed` and `warning`. Values are an authorized projection,
not an Active Record instance. Blind writes can succeed with an empty projection.

The current failure codes distinguish `NOT_FOUND`, `UNAUTHENTICATED`,
`VALIDATION_FAILED`, `CONFLICT`, `APPROVAL_REQUIRED`, `APPROVAL_EXPIRED`,
`APPROVAL_INVALIDATED` and `IDEMPOTENCY_CONFLICT`. Configuration errors raise
`ConfigurationError`; they are not a successful operation.

A callback may fail after the database has committed. In that case the business
receipt remains successful and the result carries
`warning: "POST_COMMIT_CALLBACK_FAILED"`; the warning is recorded on the run for
later replay. Do not issue a fresh intent assuming the domain change rolled back.
Inspect the host callback and reconcile any external consequence. Process death
and external effects remain host reliability boundaries; this is not a complete
external-effect recovery protocol.

## Next Steps

* [Host Verification]({% link _advanced/host-verification.md %}) exercises replay and scope contracts.
* [Data and Security]({% link _advanced/data-and-security.md %}) describes audit and logging limits.
