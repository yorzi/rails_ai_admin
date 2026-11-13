---
layout: default
title: Operations
nav_order: 2
description: Execute CRUD and member operations with bound confirmation, receipts and durable follow-up intent.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* How server-issued intents bind a human submission.
* How to register a typed member operation and authorize its inputs.
* How replay and optimistic locking protect a business write.
* How to separate a committed business result from follow-up delivery.
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

## Register a Member Operation

An operation encapsulates host domain behavior that is not ordinary attribute
editing. Member operations execute synchronously with required human
confirmation. [Collection Operations]({% link _core_features/collection-operations.md %})
use the same per-record handler through a separate fixed-manifest approval and
durable asynchronous execution path. Input declarations use the same scalar Field DSL:

```ruby
class TriageTicketOperation < RailsAiAdmin::Operation
  version "1"
  description "Triage ticket"
  max_duration 5

  input do
    text :note, required: true, nullable: false, max_length: 500
  end

  def preflight(_context, _record, input)
    { state: "triaged", internal_note: input.fetch("note") }
  end

  def perform(context, record, input)
    record.update!(state: "triaged", internal_note: input.fetch("note"))
    context.outbox.enqueue(
      "tickets.triaged", key: "notice", ticket_ref: context.ref(record)
    )
    success(record)
  end
end
```

This example expects the support host's `SupportTicket` and a registered
`"tickets.triaged"` Work handler from [Durable Outbox]({% link _advanced/durable-outbox.md %}).
The handler persists its original member target. Actual persisted attribute
changes must advance its version (`lock_version`, or `updated_at` when the model
has no `lock_version`); bypassing that, for example with `update_columns`, rolls back
with `ConfigurationError`. Return `success(record)`,
`invalid(:note)` or `conflict`; returning an arbitrary object or switching/destroying
the target is not supported.

Register it inside the existing `TicketAdmin` declaration:

```ruby
operation :triage,
  handler: "TriageTicketOperation",
  scope: :member,
  confirmation: :required
```

The handler is a class-name string and resolves through the registry. It cannot
replace `create`, `update` or `destroy`. A readonly resource also denies custom
write actions. Use `scope: :collection` only with the separate Collection Runner;
member endpoints cannot execute its parent or child intents. Global operations
and custom CRUD overrides remain unavailable.

## Grant Command, Inputs, Receipts and Delivery Separately

The normal `:write` field list does not grant custom operation inputs. A custom
adapter supplies these independent contracts:

| Decision | Custom adapter method |
| --- | --- |
| Execute command | `allowed?(context:, action: :triage, resource:, record:)` |
| Accept operation inputs | `operation_fields(context:, resource:, operation: :triage, record:)` |
| Read committed custom receipt | `read_operation_receipt?(context:, resource:, operation: :triage, record:)` |
| Deliver follow-up Work | `deliver_work?(context:, resource:, operation: :triage, work_kind: "tickets.triaged", record:)` |

Missing methods/grants deny. Operation inputs are intersected with the handler's
schema; a missing required input grant prevents access rather than letting the
handler run with incomplete authority. SQL scope and current field projection
still apply independently.

With the optional Pundit adapter, add these methods inside the existing
`TicketPolicy` from the Pundit guide:

```ruby
def triage?
  %w[operator admin].include?(context.actor.role) && show? && record.state == "open"
end

def permitted_operation_fields(operation)
  operation == :triage && %w[operator admin].include?(context.actor.role) ? [:note] : []
end

def read_operation_receipt?(operation)
  operation == :triage && show?
end

def deliver_operation_work?(operation, kind)
  operation == :triage && kind == "tickets.triaged" &&
    %w[operator admin].include?(context.actor.role) && show?
end
```

The successful transition makes `triage?` false. A retry reads the committed
receipt using `read_operation_receipt?`, so it does not need to make the command's
old precondition true again. It still rechecks identity/security version, scope,
receipt grant and input/schema binding. Successful custom-receipt replay checks
the complete bound typed schema/digest without requiring current operation-input
grants. Any failed coercion or changed input gives generic `IDEMPOTENCY_CONFLICT`
with no field errors, so hidden/unadmitted fields are not disclosed. Before an
intent succeeds, current input grants are still required. Receipt permission
does not rerun the command or grant extra readable fields. Delivery is a further
decision about an already committed fact, not re-execution of `triage?`.

## Review Through Native Forms

The normal Rails path, relative to the mount, is:

1. `GET /:resource/:id/operations/:operation` presents permitted inputs.
2. `POST /:resource/:id/operations/:operation/preflight` creates an input-bound
   proposal and displays the exact target/input and authorized changes.
3. `POST /:resource/:id/operations/:operation/execute` consumes its human
   confirmation through the shared Runner.

With Turbo, a successful review replaces the operation form with its confirmation
through a Turbo Stream response. Without JavaScript it renders an ordinary HTML
confirmation. Execution redirects with HTTP 303 after success.

Editing input requires a new review. Preflight returns proposed values keyed by
resource field name; the framework obtains readable original values and filters
and coerces the preview. Scoped lookup, authorization, input resolution and the
handler all run under Active Record `while_preventing_writes`; the intent is
created only after that read-only path finishes. In-memory target mutation is
rejected. This only guards supported Active Record writes. It is not a sandbox for trusted Ruby, files, raw connections or
HTTP calls. Keep this whole preflight path pure and test it in the host.
Unexpected ordinary preflight failures return `OPERATION_FAILED` rather than
original diagnostics; ConfigurationError and AccessDenied can still raise. Host
code that explicitly logs its own sensitive diagnostics cannot be suppressed by
this boundary.

Trusted integrations can use the same Ruby API:

```ruby
proposal = RailsAiAdmin::Operations::Runner.new.preflight(
  context: context,
  resource: TicketAdmin,
  operation: :triage,
  target_id: ticket.id,
  expected_version: ticket.lock_version,
  input: { "note" => "Reviewed support request" }
)
```

On valid input this returns a Proposal with `intent`, typed `values` and visible
`changes`; typed input/time-limit failures can return `Operations::Result`.
Other ordinary preflight failures become `OPERATION_FAILED`.
Authorization/configuration failures can still raise. Handle failure before
showing confirmation. Only after an actual human reviews this proposal:

```ruby
result = RailsAiAdmin::Operations::Runner.new.execute(
  context: context,
  intent_ref: proposal.intent.id,
  input: proposal.values,
  human_confirmed: true
)
```

Unlike editable ordinary CRUD forms, custom operations require input-bound
preflight; `input: nil` cannot create an unbound custom intent.

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

The fingerprint includes the policy mapping and operation definition/version.
Changing these invalidates existing development intents. Bump the operation
version deliberately when its business semantics change; Ruby method bodies are
not automatically fingerprinted. Existing
development form/proposal intents then return `APPROVAL_INVALIDATED`; reopen the
form and review its current permissions instead of reusing the old intent. The
fingerprint is not a substitute for current action and field authorization.

## Require a Shared Connection and Record Version

Writes require one primary key and a record version: standard `lock_version`
optimistic locking when the model has it, otherwise an `updated_at` timestamp
(Rails' default precision of microseconds). With `updated_at`, the Runner loads
the target with a row lock and compares the timestamp inside the write
transaction, so the version column itself can never be a writable field.
Host domain models, `OperationRun`, `AuditEvent` and `WorkItem` must share the same
connection pool. Cross-pool writes, shards, composite keys and MySQL writes are
unsupported. A database-level rollback also rolls back the successful receipt and
audit. SQLite write contention can return a retryable `CONFLICT`; retry with the
same still-valid intent rather than issuing a second business operation.

Custom handlers can declare additional participating model names with
`atomic_models "TicketEvent"`; every declared model must share that pool. This is
not permission to access another model or a discovery mechanism for arbitrary
Ruby writes. The host must scope and lock related records correctly. Handlers may
use a normal same-pool transaction that joins the outer transaction, but must
not open `requires_new` transactions or call external systems while holding the
domain transaction. `max_duration` is a soft before/after execution check, not a
hard interrupt for Ruby or SQL.

A host callback that sends mail, charges money or performs HTTP is not made safe
by wrapping `save!` in a transaction. Keep that resource readonly until its boundary
is redesigned. A registered [Work handler]({% link _advanced/durable-outbox.md %})
can deliver a declared effect after commit; it is not an asynchronous domain
execution path or a blanket solution for existing unsafe callbacks.

## Inspect Results Without Assuming Rollback

`Result` exposes `code`, `status`, `success?`, `retryable?`, `record_id`, `audit_ref`,
`values`, `errors`, `replayed`, `warning` and `work_refs`. Values are an authorized projection,
not an Active Record instance. Blind writes can succeed with an empty projection.

The current failure codes distinguish `NOT_FOUND`, `UNAUTHENTICATED`,
`VALIDATION_FAILED`, `CONFLICT`, `APPROVAL_REQUIRED`, `APPROVAL_EXPIRED`,
`APPROVAL_INVALIDATED`, `IDEMPOTENCY_CONFLICT`, `TIMEOUT` and `OPERATION_FAILED`.
Configuration errors raise
`ConfigurationError`; they are not a successful operation.

A callback may fail after the database has committed. In that case the business
receipt remains successful and the result carries
`warning: "POST_COMMIT_CALLBACK_FAILED"`; the warning is recorded on the run for
later replay. Do not issue a fresh intent assuming the domain change rolled back.
Inspect the host callback and reconcile any external consequence. Process death
and external effects remain host reliability boundaries; this is not a complete
external-effect recovery protocol.

A successful result with `work_refs` means the business operation committed and
follow-up intent is durable. It does not mean external delivery completed. Work
status, attempts, deadlines and uncertain effects are separately tracked.

## Next Steps

* [Durable Outbox]({% link _advanced/durable-outbox.md %}) defines delivery authority, scanning and unknown outcomes.
* [Host Verification]({% link _advanced/host-verification.md %}) exercises replay and scope contracts.
* [Data and Security]({% link _advanced/data-and-security.md %}) describes audit and logging limits.
