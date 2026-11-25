---
layout: default
title: "Tasks and Approvals"
nav_order: 20
description: "One page per tenant for proposals waiting for review, background jobs in progress, and finished operations you can inspect or undo."
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

0.7.0 is in development; this page describes the `main` branch.
{: .note }

After reading this guide, you will know:

* How to open the Tasks page.
* What each tab shows and who sees which task.
* How to approve, dismiss or undo from a task.
* What a task records.

## Open the Tasks Page

Grant it in your authorization adapter:

```ruby
def view_tasks?(context:)
  context.actor.staff?
end
```

The header then shows **Tasks**, with the number of proposals you may approve
(up to "9+"). With the Pundit adapter, define `view_tasks?` on any resource
policy; one that returns `true` opens the page. `FullAccessAdapter` grants it.

A task is created for you, never by hand:

* when an operation that needs another approver is proposed;
* when a collection operation or a large bulk change is queued to run in the
  background;
* when an operation that can be undone succeeds.

Tasks coordinate; they do not run anything. The operation run, its selection
and its background items stay the source of truth, and a task's status is
derived from them.

## Find a Task

The page has four tabs:

* **Needs approval**: proposals you may approve now. A proposal you made
  yourself in `:separate_actor` mode is never here.
* **Active**: proposals waiting for review and background jobs that are
  running.
* **Completed**: succeeded, failed, cancelled and expired tasks.
* **My tasks**: everything you proposed.

Every list stays inside the current tenant. You see a task you created, a task
you may approve, or a task whose operation receipt you may read
(`read_operation_receipt?`); others stay hidden, including their titles.
Filter with `?resource=orders` or `?kind=bulk_job`.

## Approve or Dismiss a Proposal

A proposal's page shows the input that will execute, each target record with
the changes recomputed under your grants (the first 25 records of a larger
selection), and its expiry. If a target changed since the proposal, the page
says so and offers no Approve button; ask for a new proposal.

**Approve and execute** runs the same checks as any confirmation: your
`approve_operation?` grant, the operation grant, the input fields and the
record version. An optional note (up to 500 characters) is stored on the run.

**Dismiss proposal** is available to the proposer and to anyone who may
approve. It cancels the proposal, writes an audit event naming who dismissed
it, and fails with a conflict if someone approved it first.

## Follow a Background Job

While a job runs, its task page refreshes itself and links to the job's
detail page, where you can cancel the remaining items or, after a partial
failure, **Review failed records for retry**. In a chat that proposed a large
bulk change, the same progress appears under the review card.

## Undo a Finished Operation

A succeeded task whose operation can be undone shows what an undo will do (the
fields and the values they return to, a restore, or the operation's own
compensation) above an **Undo operation** button. See
[Approvals, Verification and Undo]({% link _core_features/approvals-and-undo.md %})
for the grants and limits.

## Read the Timeline

Each task keeps an append-only timeline of its status changes (awaiting
approval, executing, finished, cancelled, expired) and of an undo, with the
person and time of each event. The timeline holds codes and short
server-written messages, never field values.

## Next Steps

* [Approvals, Verification and Undo]({% link _core_features/approvals-and-undo.md %}) - declare approval modes, verify hooks and undo.
* [Collection Operations]({% link _core_features/collection-operations.md %}) - background execution, cancellation and retry.
* [Admin Chat]({% link _advanced/admin-assistant.md %}) - bulk changes proposed in a conversation.
