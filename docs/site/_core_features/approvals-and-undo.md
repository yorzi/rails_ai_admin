---
layout: default
title: "Approvals, Verification and Undo"
nav_order: 19
description: "Require a second person to approve risky operations, check each result after it commits, and undo a committed change once, all under current grants."
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

0.7.0 is in development; this page describes the `main` branch. These features
need the four engine migrations added in 0.7; see
[Upgrading]({% link _reference/upgrading.md %}).
{: .note }

After reading this guide, you will know:

* How to require another person to approve an operation.
* How to check an operation's result after it commits.
* How to make a custom operation reversible.
* How to let people undo native updates and soft deletes.
* Which grants each step needs.

## Require a Second Person

A refund or a merge is safer when the person who prepares it is not the person
who confirms it. Declare the approval mode on the operation class:

```ruby
class RefundOrderOperation < RailsAiAdmin::Operation
  approval_mode :separate_actor

  input do
    decimal :amount, required: true, nullable: false
  end

  def preflight(_context, record, input)
    { refunded_total: record.refunded_total + input.fetch("amount") }
  end

  def perform(_context, record, input)
    record.update!(refunded_total: record.refunded_total + input.fetch("amount"))
    success(record)
  end
end
```

or per resource, which overrides the class:

```ruby
operation :refund, handler: "RefundOrderOperation", approval: :separate_actor
```

There are three modes:

* `:self` (the default) keeps the single-person flow: whoever prepares the
  intent confirms it.
* `:separate_actor` forbids the proposer from confirming. A confirmation by the
  proposer is refused with `SELF_APPROVAL_FORBIDDEN` and audited; nothing is
  written.
* `:any_reviewer` lets anyone with the approval grant confirm, the proposer
  included.

Native `create`, `update` and `destroy` always use `:self`. The approval mode is
part of the operation's fingerprint, so tightening it invalidates intents that
are still open.

The proposer prepares the operation as usual. Instead of a Confirm button,
their review shows that it is waiting for another reviewer, and the proposal
appears under **Needs approval** on the
[Tasks]({% link _core_features/tasks.md %}) page of everyone who may approve
it. The approver sees the proposed input, the target and the changes
recomputed under their own grants, adds an optional note, and approves.

Approving needs a new grant on your authorization adapter, plus everything
the operation itself needs:

```ruby
def approve_operation?(context:, resource:, operation:, record: nil, proposed_by_actor_ref: nil)
  operation == :refund && context.actor.finance_lead?
end
```

With the Pundit adapter, define it on the resource's policy; it receives the
operation and the proposer's reference:

```ruby
def approve_operation?(operation, proposed_by_actor_ref)
  operation == :refund && context.actor.finance_lead?
end
```

The approver must also pass `allowed?` for the operation and hold its input
fields through `operation_fields`. The run records both people:
`proposed_by_actor_ref`, `approved_by_ref`, the approver's security version and
the note; the audit event records both as well. Collection operations work the
same way, and their background workers act with the approver's current
authority: if the approver loses the grant or their security version changes,
the remaining items stop.

`FullAccessAdapter` never grants `approve_operation?`; the doctor reports
whether your subclass overrides it.
{: .important }

## Check the Result After It Commits

A merge can succeed and still leave something odd behind. A `verify` method
runs after the business write has committed and reports checks:

```ruby
class MergeCustomersOperation < RailsAiAdmin::Operation
  # ... input, preflight and perform

  def verify(context, target, input)
    remaining = Invoice.where(customer_id: input.fetch("source")).count
    if remaining.zero?
      [ check_pass("invoices_moved", "All invoices moved to #{target.name}") ]
    else
      [ check_fail("invoices_moved", "#{remaining} invoices still point at the source") ]
    end
  end
end
```

Return up to 20 checks built with `check_pass`, `check_warn` and `check_fail`
(a name such as `invoices_moved` and a short message), or `nil` for "passed".
The run stores the overall status: `passed`, `warning`, `failed`, or `error`
when `verify` raised. `verify` runs with writes prevented, in its own
savepoint, so a failing check, an exception, a database error or an attempted
write never rolls back the committed change. The result appears on the task
page, in the execution receipt and as `result.verification` from
`Runner#execute`.

## Make a Custom Operation Reversible

A reversible operation saves what it needs to put things back, then knows how
to do it:

```ruby
class MergeCustomersOperation < RailsAiAdmin::Operation
  reversible true

  def undo_snapshot(context, target, input)
    source = Customer.find(input.fetch("source"))
    { "source_id" => source.id, "source_points" => source.points,
      "moved_invoice_ids" => source.invoices.pluck(:id) }
  end

  def compensate(context, target, snapshot)
    source = Customer.lock.find(snapshot.fetch("source_id"))
    Invoice.where(id: snapshot.fetch("moved_invoice_ids")).update_all(customer_id: source.id)
    source.update!(points: snapshot.fetch("source_points"))
    target.update!(points: target.points - snapshot.fetch("source_points"))
    success(target)
  end
end
```

`undo_snapshot` runs read-only just before `perform` and must return a
JSON-safe Hash of at most 16 KB. `compensate` runs inside the Runner's normal
transaction and returns `success`, `invalid` or `conflict` like `perform`. Do
not put secrets in the snapshot; it is stored on the run.

## Undo Native Updates and Soft Deletes

For ordinary edits, opt a resource in:

```ruby
class CustomerAdmin < RailsAiAdmin::Resource
  soft_delete :discarded_at
  undoable :update, :destroy
end
```

`undoable :update` saves the previous values of the fields an update changed.
Password, file, rich text and reference-list fields, hidden fields and virtual
fields are never saved, so an undo cannot restore them. `undoable :destroy`
needs `soft_delete`; undoing it restores the record.

## Grant and Limit Undo

Undo needs its own grant:

```ruby
def undo_operation?(context:, resource:, operation:, record: nil)
  context.actor.admin?
end
```

With Pundit, define `undo_operation?(operation)` on the policy. Undo also
needs the grant of the action it mirrors: `update` and the write
fields for an update, `restore` for a soft delete. An undo:

* runs only while the record is still at the version the operation left, so
  a later edit makes it a `CONFLICT`;
* runs at most once per operation;
* is a new run with its own audit event (`undo_update`, `undo_destroy` or
  `undo_<operation>`), never an edit of the original;
* is not available for collection runs.

The **Undo operation** button on the task page shows what will be restored
first. `FullAccessAdapter` grants `undo_operation?`.

## Next Steps

* [Tasks and Approvals]({% link _core_features/tasks.md %}) - where proposals wait and where undo is offered.
* [Operations]({% link _core_features/operations.md %}) - the intent and confirmation flow these features build on.
* [Collection Operations]({% link _core_features/collection-operations.md %}) - approval and background execution for many records.
