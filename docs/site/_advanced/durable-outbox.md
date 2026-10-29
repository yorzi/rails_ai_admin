---
layout: default
title: Durable Outbox
nav_order: 4
description: Persist one post-commit delivery intent with explicit authority and recovery boundaries.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* How to register typed Work and enqueue it with a member operation.
* How delivery authority, stable keys and request digests constrain retries.
* How to schedule recovery without claiming downstream exactly-once execution.

## Register a Delivery Handler

Work is post-commit delivery of an already committed operation, not an asynchronous
business-operation runner. It inherits the Operation input DSL and implements
`perform(context, input)` with two arguments:

```ruby
class TicketNoticeWork < RailsAiAdmin::Work
  version "1"
  idempotent true
  lease_duration 60
  max_attempts 3
  max_age 1.day
  record_version_policy :exact

  input do
    text :ticket_ref, required: true, nullable: false, max_length: 150
  end

  def perform(context, input)
    request = {
      "event" => "ticket.triaged",
      "ticket_ref" => input.fetch("ticket_ref")
    }
    context.effect(request: request) do |delivery|
      TicketNoticeTransport.deliver(
        request: request,
        idempotency_key: delivery.delivery_key
      )
    end
  end
end
```

`TicketNoticeTransport` is your host's transport contract, not a class supplied by
this gem. It must submit the request represented by `request`, return only for a
known successful outcome, and raise for a failed or unknown outcome. Merely
returning an HTTP error response does not tell the dispatcher it failed. Only set
`idempotent true` when the actual downstream system enforces the stable key for
the entire request. The default is false.

Configure the kind using strings before boot:

```ruby
RailsAiAdmin.configure do |config|
  config.work_handlers = { "tickets.triaged" => "TicketNoticeWork" }
  config.outbox_auto_dispatch = false
end
```

The registry resolves reloadable class names. Changing handler semantics requires
a deliberate version bump; the fingerprint does not hash Ruby method bodies.
Missing/changed handler contracts stop pending work for reconciliation.

## Enqueue Inside the Domain Operation

Inside `Operation#perform`, after updating the authorized target:

```ruby
context.outbox.enqueue(
  "tickets.triaged",
  key: "notice",
  ticket_ref: context.ref(record)
)
```

The complete member operation is shown in [Operations]({% link _core_features/operations.md %}).
You can supply `input: { "ticket_ref" => context.ref(record) }` instead of keyword
attributes, but not both. `context.ref` accepts only that operation's scoped target.
Enqueue requires its active Runner transaction; it does not contact a queue or
provider. Payload, payload digest and the WorkItem commit with domain data,
confirmation, audit and the business receipt. A failed operation commits none of
those successful effects.

The work key is unique within the operation run. A repeated enqueue with that same
key and identical contract returns the same Work ref. Changing the kind, payload
or handler fingerprint under that pair conflicts. Payload JSON is limited to
4096 bytes and keys to bounded strings. Store the minimum delivery data; Work
payloads persist their declared values and are not a credential vault.

## Rebuild Current Delivery Authority

A queued item must not reuse a request's cached actor or tenant. Your context
adapter must also implement:

```ruby
def resolve_job(actor_ref:, tenant_ref:, security_version:)
  actor_match = actor_ref.match(/\Araa:actor:StaffUser:(\d+)\z/)
  tenant_match = tenant_ref.match(/\Araa:tenant:Tenant:(\d+)\z/)
  return unless actor_match && tenant_match

  actor = StaffUser.find_by(id: actor_match[1])
  tenant = actor&.tenants&.find_by(id: tenant_match[1])
  return unless actor && tenant

  RailsAiAdmin::Context.new(
    actor: actor,
    tenant: tenant,
    security_version: actor.security_version.to_s
  )
end
```

This example matches the packaged support host's bigint StaffUser/Tenant identity
types. Adapt your codec for other classes/UUIDs; never constantize arbitrary refs.
Read the current actor version rather than constructing authority from the stored
`security_version` argument. The dispatcher requires the reconstructed typed
actor/tenant refs and version to match the admitted run, obtains a current scoped
target and checks the independent delivery permission again at the effect boundary.
A missing resolver does not fall back to an anonymous or system-wide actor.

Custom adapters grant `deliver_work?(context:, resource:, operation:, work_kind:,
record:)`. Pundit policies grant `deliver_operation_work?(operation, kind)`.
Permission to run a command or read its receipt does not grant delivery permission.
The triage example uses `:triage` and `"tickets.triaged"` as the exact operation/kind.

## Distinguish Admission, Record Version and Delivery Deadline

The operation consumes its approval when the domain transaction and WorkItem are
accepted. Work then has its own `deadline_at`, derived from `max_age`; expiry of
the already consumed intent TTL does not by itself cancel that work. Current
authority and the Work deadline still apply, and no new targets are admitted.

The default `record_version_policy :exact` requires the target's current
`lock_version` to equal its version at operation commit. A later legitimate edit
stops delivery with `RECORD_CHANGED` and `reconciliation_required`. Explicitly use
`:current` only when the workflow safely uses current state. It still checks
current scope/authority and cannot change an already bound external request under
the same delivery key.

One item permits exactly one `context.effect` call. Pass the actual semantic
request, including target and business body, then give that same object to the
transport. This must be a plain JSON Hash with string/symbol keys and values
limited to String, Integer, finite Float, boolean, nil, Hash or Array. Keys must
not collide after conversion to strings. Nested data is limited to depth eight and 16 KiB JSON. Serialize
BigDecimal, Date and Time to the actual wire values yourself before this boundary.
The dedicated RequestDigest does not reuse typed-input marker serialization.
The framework stores this request digest before the effect. A changed request
on retry becomes `REQUEST_CHANGED` and is not sent under the original key. Resolve
transport credentials from host configuration rather than putting them in Work
payloads or logs. Trusted Ruby is not sandboxed: a handler must not bypass the
boundary with additional network calls or mutate domain records here. Ordinary
Active Record writes in the Work body, delivery authorization and RPC/effect
block are protected by `while_preventing_writes`; only short framework CAS
bookkeeping temporarily enables writes. That guard is not a trusted-Ruby sandbox
and must not be disabled to make unaudited business updates.

## Schedule Recovery

```sh
bin/rails rails_ai_admin:work:scan
bin/rails rails_ai_admin:work:drain
```

Choose the host scheduling/queue arrangement appropriate to your installation.
`scan` schedules up to 100 due pending or expired-lease items using Active Job.
`drain` visits up to 100 inline, outside domain transactions. Repeated scans are
required for delayed retries, missed enqueue and expired-lease recovery; neither
command installs a recurring scheduler. Use a persistent job queue for scheduled
delivery. Do not leave a development worker running as an implicit scheduler.

`outbox_auto_dispatch` is false by default. Enabling it adds an after-commit
Active Job enqueue accelerator. It cannot close the crash window between commit
and enqueue, so the host must still schedule a periodic scan.

For trusted operational tooling, a single item can be visited directly:

```ruby
delivery_result = RailsAiAdmin::Outbox::Dispatcher.new.run(work_ref)
```

`Outbox::Dispatcher::Result` exposes `work_ref`, `status`, `code` and `success?`.
Work status is separate from the successful business receipt. A pending Work ref
in `Operations::Result#work_refs` means follow-up delivery is tracked, not complete.

## Interpret Retries and Unknown Outcomes

Claims use a lease owner and increasing generation. Checks before the effect and
receipt updates fence old workers; a stale response cannot overwrite a newer
owner's state. An old request already in flight cannot be recalled by a fence.
Use host transport timeouts compatible with the lease, and design the downstream
idempotency contract explicitly.

Before an effect starts, revocation can cancel the item without reversing the
successful domain operation. Once an outcome is unknown, revocation cannot turn
it into a definite unsent cancellation. Non-idempotent unknown outcomes require
reconciliation and are not automatically retried. Declared idempotent retries
reuse the same delivery key and request digest, within their attempt/deadline
limits. Attempt exhaustion, changed contracts and expired uncertain work also
need explicit review.

When a current owner has observed a successful effect, a later local callback
failure or authority change does not rewrite it as unsent. It can retain
`succeeded` with `POST_EFFECT_CALLBACK_FAILED`. A lost fence is reported as
`FENCED` and cannot rewrite a newer owner's receipt. Process death after a remote
response but before a local receipt can still leave an unknown outcome.

Database persistence, one framework effect boundary and generation fencing do not
prove downstream exactly-once execution. Reconcile terminal uncertain items with
the downstream system; do not force status changes or issue fresh keys assuming
nothing happened. No general reconciliation UI or external-provider guarantee is
implemented by this slice.

## Next Steps

* [Operations]({% link _core_features/operations.md %}) defines the admitted domain action and separate grants.
* [Data and Security]({% link _advanced/data-and-security.md %}) covers durable payload and logging boundaries.
* [Development Status]({% link _reference/development-status.md %}) keeps unimplemented workflows and release Gates explicit.
