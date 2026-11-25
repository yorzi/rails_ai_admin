---
layout: default
title: What's New in 0.7
nav_order: 6
description: A second person can approve risky operations, results are checked after they commit, committed changes can be undone once, large bulk changes run in the background, and one Tasks page shows what waits and what ran.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

0.7.0 is in development; this page describes the `main` branch. It builds on
[What's New in 0.6]({% link _getting_started/whats-new-in-0-6.md %}).
{: .note }

After reading this guide, you will know:

* How to make an operation need a second approver.
* Where proposals wait and how an approver reviews them.
* How to check a result after it commits.
* How to undo a committed change.
* How to change more than 100 records at once.
* What the new review Surfaces show.
* What to do when you upgrade.

## Ask a Second Person to Approve

A refund or a merge can now need someone other than its proposer:

```ruby
operation :refund, handler: "RefundOrderOperation", approval: :separate_actor
```

The proposer prepares it as before, but cannot confirm it. Anyone your policy
grants `approve_operation?` reviews and confirms it, and the run and the audit
log record both people. See
[Approvals, Verification and Undo]({% link _core_features/approvals-and-undo.md %}).

## One Page for Tasks

**Tasks** in the header lists proposals you may approve, jobs that are running,
finished operations and your own proposals, behind the `view_tasks?` grant. A
proposal's page shows exactly what will execute and the changes recomputed for
the approver, and refuses approval when a target has changed since. See
[Tasks and Approvals]({% link _core_features/tasks.md %}).

## Check the Result

A custom operation can define `verify`. It runs after the write commits and
reports passed, warning or failed checks, shown on the task and the receipt. A
failing or broken check never rolls the write back.

## Undo Once

`reversible true` with `undo_snapshot` and `compensate` makes a custom
operation reversible; `undoable :update, :destroy` does the same for native
updates and soft deletes. The task page shows what an undo restores, and the
undo needs `undo_operation?` plus the update or restore grant, works only while
nobody has changed the record since, and only once.

## Change More Than 100 Records

Collection operations and assistant bulk changes now take up to
`config.async_bulk_limit` records (1,000 by default). The review previews 25 and
checks the rest; confirming queues one background job, and the chat that
proposed it shows the job's progress. A job with failures offers **Review
failed records for retry**. See
[Collection Operations]({% link _core_features/collection-operations.md %}#run-more-than-100-records).

The assistant's `propose_bulk_change` also accepts `any` and `relation_filters`,
like `search_records`.

## Review Surfaces

`surface: :editable` lets a reviewer change an operation's inputs inside the
Surface before confirming; each change replaces the intent with a freshly
checked one. A confirmed review now shows its receipt: the changed fields you
may read, verification results, follow-up Work and a link to undo. See
[Review Surfaces]({% link _advanced/review-surfaces.md %}).

## Upgrading

0.7 adds four migrations and layout contract 7. Run the installer with `--skip`,
migrate, add the Tasks link to a copied layout, and add the new grants you
want. See [Upgrading]({% link _reference/upgrading.md %}#upgrade-to-070).

## Next Steps

* [Approvals, Verification and Undo]({% link _core_features/approvals-and-undo.md %}) - declare approval modes, verify hooks and undo.
* [Tasks and Approvals]({% link _core_features/tasks.md %}) - review proposals and follow jobs.
* [Upgrading]({% link _reference/upgrading.md %}) - migrations, layout and grants.
