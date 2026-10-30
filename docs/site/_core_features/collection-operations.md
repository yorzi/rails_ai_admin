---
layout: default
title: Collection Operations
nav_order: 4
description: Approve exact fixed targets once and execute their database changes as durable independent items.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* How to register a per-record handler for an asynchronous collection command.
* How fixed targets and typed input bind one parent approval.
* How workers recheck authority and commit each target independently.
* How to recover queued work and cancel remaining items without undoing success.

## Register a Per-Record Handler

A collection operation applies one declared `Operation` to each record in a fixed
[Selection]({% link _core_features/selections.md %}). It is always asynchronous;
admission does not mutate business records. Given a host `Customer` model with
integer `points` and standard `lock_version`, define:

```ruby
class AwardCustomerPoints < RailsAiAdmin::Operation
  version "1"
  description "Award customer points"
  max_duration 5
  lease_duration 60
  execution_window 1.hour
  max_attempts 3

  input do
    integer :amount, required: true, nullable: false
  end

  def preflight(_context, record, input)
    { points: record.points + input.fetch("amount") }
  end

  def perform(_context, record, input)
    record.update!(points: record.points + input.fetch("amount"))
    success(record)
  end
end

class PointsCustomerAdmin < RailsAiAdmin::Resource
  model "Customer"
  key :customers
  title :name

  fields do
    id :id
    text :name
    integer :points
  end

  operation :award_points, handler: "AwardCustomerPoints",
    scope: :collection, confirmation: :required
end
```

Register `"PointsCustomerAdmin"` in `config.resources`, using it in place of another
resource with the same key. The handler has the same per-record
`preflight(context, record, input)` and `perform(context, record, input)` contract
as a member operation. Input has typed string keys. Preflight returns proposed
resource values without mutation; perform persists its original scoped target
and returns `success(record)`, `invalid(*input_fields)` or `conflict`. Actual
attribute changes must advance `lock_version`.

Readonly/disabled resources deny writes. Collection registration cannot override
CRUD keys or become a global command. Public member `prepare`, `preflight` and
`execute` cannot execute a collection operation or its child intent. Workers use
the admitted parent and a server-created lease claim, not synthetic independent
human confirmations for each child.

## Grant Each Boundary Separately

The host still owns authentication, a complete tenant scope and field grants.
It must also grant these independent decisions:

| Decision | Custom adapter | Explicitly mapped Pundit policy |
| --- | --- | --- |
| Capture/revalidate selection | `select_records?(context:, resource:)` | `select_records?` on model class |
| Command | `allowed?(context:, action:, resource:, record:)` | Registered predicate, here `award_points?` |
| Typed input | `operation_fields(context:, resource:, operation:, record:)` | `permitted_operation_fields(operation)` |
| Parent/item receipt | `read_operation_receipt?(context:, resource:, operation:, record:)` | `read_operation_receipt?(operation)` |
| Cancel remaining items | `cancel_operation?(context:, resource:, operation:)` | `cancel_operation?(operation)` on model class |
| Deliver committed Work | `deliver_work?(context:, resource:, operation:, work_kind:, record:)` | `deliver_operation_work?(operation, kind)` on record |

Missing methods/grants deny. The command and input grants are checked first at
collection level (`record: nil` for a custom adapter, model class for Pundit), then
for every target during review/admission and again for execution. For this example,
input grants must include `:amount`. A policy predicate used at class level must
handle that target; it cannot blindly read instance attributes. Each selected
record also needs current index/show/scope/read access for the Selection preview.

The parent and every item belong to the original actor/tenant/security version.
`context_adapter.resolve_job(actor_ref:, tenant_ref:, security_version:)` must
freshly rebuild that authority from trusted refs, current actor and verified tenant
membership. Returning a cached actor or trusting the stored security version is
insufficient. There is no system-actor fallback. Receipt/cancel grants do not
bypass ownership, epoch or resource-contract checks.

## Review and Admit the Exact Manifest

Given the current authenticated `context`, registered resource and two visible
customers in its tenant:

```ruby
selection = RailsAiAdmin::Selections::Builder.new.capture(
  context: context, resource: PointsCustomerAdmin,
  target_ids: [customer.id, second_customer.id]
)
runner = RailsAiAdmin::Collections::Runner.new
proposal = runner.preflight(
  context: context, resource: PointsCustomerAdmin, operation: :award_points,
  selection_ref: selection.selection_ref, input: { "amount" => "8" }
)
raise proposal.code if proposal.is_a?(RailsAiAdmin::Collections::Result)
```

Preflight returns `Collections::Runner::Proposal(intent, values, targets)` or a
handled `Collections::Result`. Each target has `id`, current permitted `label`
and readable `changes`. Handle failure before showing confirmation; configuration
failures can raise. Scoped lookup, authorization, input and handler previews use
the Active Record read-only guard. This protects ordinary Active Record writes,
not arbitrary Ruby, raw connections, files or external calls. Host policy and
preflight code must remain pure. Proposal preflight runs outside the parent lock
with a cooperative 30-second aggregate budget, alongside each handler
`max_duration`; neither check hard-interrupts Ruby or SQL.

The proposed parent binds the exact canonical IDs/versions, Selection digest,
resource/operation contract and normalized input digest. New matches, changed
versions and same-count replacement targets cannot silently enter the run.
Preflight stores typed wire input on the parent once, bounded to 4 KiB; target
preview changes are bounded to 256 KiB. Unlike Selection metadata, this is
persisted business input: exclude credentials and secrets. The input payload is
not displayed in job details or copied into each child/audit. Host SQL/debug or
explicit application logging remains a host responsibility.

Only after a human reviews the exact proposal:

```ruby
admitted = runner.admit(
  context: context, intent_ref: proposal.intent.id,
  input: proposal.values, human_confirmed: true
)
raise admitted.code unless admitted.accepted?
```

Trusted request handling supplies `human_confirmed`; never accept an assistant's
claim of approval or use it to approve another manifest. Native handling also
binds resource/operation/selection to the endpoint. The optional Ruby `binding:`
hash uses `resource_key:`, `operation:` and `selection_id:` for that same check.

Admission locks the parent and rechecks the still-live Selection
metadata/digest, exact scope/show/versions and class/per-target command/input
grants. It consumes approval without repeating host preflight or title projection
under that lock, then atomically creates child intents, `BatchItem` rows, parent
approval and its admission audit. It performs no domain mutation. A repeated
same-parent/same-input admission returns the same job with `replayed: true`, not
another target set. Changed replay input gives generic `IDEMPOTENCY_CONFLICT`.
Replay needs current parent receipt authority and uses the bound complete input
schema rather than granting another command.

`Collections::Result` exposes `code`, `job_ref`, `status`, `errors`, `replayed` and
`warning`. `accepted?` means a queued/existing job was accepted; `success?` means
its aggregate status is `succeeded`. A `QUEUED` response is not business success.
If admission commit/read recovery cannot establish the durable outcome,
`OUTCOME_UNKNOWN` retains the same `job_ref` with status `unknown`. Check the job
and retry the same intent/input; do not create another approval assuming nothing
committed. A known committed receipt is preserved. Two independently approved
parent intents do not deduplicate by matching input.

## Use the Native Confirmation Flow

The Selection preview links to permitted collection commands. Paths below are
relative to the engine mount; Rails forms use host sessions and CSRF protection.
No JavaScript is required.

| Request | Behavior |
| --- | --- |
| `GET /:resource/operations/:operation?selection_ref=...` | Current permitted input form |
| `POST /:resource/operations/:operation/preflight` | Pure review with exact targets, input and visible changes |
| `POST /:resource/operations/:operation/execute` | Explicit **Confirm and queue**, then 303 to the job |
| `GET /jobs/:job_ref` | Current authorized per-item receipts and separate Work status |
| `POST /jobs/:job_ref/cancel` | Cancel remaining items, then 303 to the job |
| `GET /jobs` | Up to 50 recent accessible runs for the current owner/tenant/epoch |

Changing inputs requires another review. Confirmation carries a bounded JSON
`confirmed_input`, parent intent ref and selection ref; tampering cannot change
the stored approval. Job views use independent class-level receipt permission and
current per-record scope/show/receipt/read grants, so a command's postcondition
does not hide its original result. Hidden records are omitted, hidden titles use
`Record #id`, and separate delivery permission controls visible Work status.
No historical business-input or full before/after snapshot is exposed there.

## Execute and Recover Through Host Workers

The host supplies a persistent Active Job queue and a recurring scan. Neither a
scheduler nor a queue service is installed. Defaults leave automatic dispatch off:

```ruby
RailsAiAdmin.configure do |config|
  config.collection_auto_dispatch = false
end
```

```sh
bin/rails rails_ai_admin:collections:scan
bin/rails rails_ai_admin:collections:drain
```

`scan` enqueues up to 100 due runs; `drain` visits them inline. Trusted worker code
can also call:

```ruby
dispatcher = RailsAiAdmin::Collections::Dispatcher.new
dispatcher.scan_pending!(limit: 100, inline: false)
result = dispatcher.run(admitted.job_ref, limit: 100)
```

`run` visits at most 100 items per call and must run outside an existing database
transaction. Scans accept limits from 1 through 1,000. Setting
`collection_auto_dispatch = true` only accelerates after-commit enqueue; recurring
scans must recover missed enqueue, queue loss and process death. Dispatching a
collection does not dispatch its separate Work items: configure the outbox scan
and real downstream delivery protocol independently.

A claim records lease owner and increasing generation. The shared Runner locks
the parent/item and verifies manifest, child binding, current actor/tenant/epoch,
class-level (`record: nil`) and per-record command/input grants, target version,
lease and deadline. Class-level revocation returns `AUTHORIZATION_REVOKED` and
stops remaining items; workers do not reconsume the Selection or require its
`select_records?` permission again. It commits the domain
write, audit, child receipt, any outbox intent, item success and parent aggregate
in one transaction. A final lease/deadline check follows output projection and
item metadata before transaction exit. Failure-audit metadata also has a final
lease check; a stale job stops before taking another claim. A stale worker cannot
finalize another generation's result.
Each target commits independently; a later failure cannot roll back earlier
success. Ordinary handler errors may retry with bounded backoff; validation or
version conflicts are not silently re-approved.

| Handler setting | Default | Supported bound |
| --- | --- | --- |
| `max_duration` | 5 seconds | Positive, at most 30 seconds; cooperative check |
| `lease_duration` | 60 seconds | 5 through 3,600 seconds, greater than `max_duration` |
| `execution_window` | 1 hour | 60 seconds through 7 days |
| `max_attempts` | 3 | Integer 1 through 10 |

The Selection and proposed approval must be live at admission. Once admitted,
execution uses its own deadline; expiry of the already consumed approval does
not cancel a job. The deadline stops remaining work. Duration/deadline checks do
not hard-interrupt arbitrary Ruby or SQL. Domain and all receipt/audit/Work/batch/
Selection tables must share one SQLite/PostgreSQL pool with standard
`lock_version`. Same-pool `atomic_models` declarations do not authorize or lock
related records. Normal joining transactions are allowed; `requires_new` inside
the handler is rejected. Collection admission, cancellation, claim and worker
execution must start outside an already open host transaction; they own the commit
boundary. Keep external effects in declared post-commit Work.

## Cancel Remaining Items and Interpret Partial Results

With the independent cancel grant, trusted host code may call:

```ruby
cancelled = runner.cancel(context: context, job_ref: admitted.job_ref)
```

Cancellation of a proposed parent blocks admission. For an admitted run it stops
uncommitted items. Item execution and cancellation serialize on the parent lock:
a target that commits before cancellation remains successful, with its audit,
receipt and outbox. Cancellation does not recall a committed change, cancel its
Work or undo an external effect. A terminal run retains its terminal status. If commit observation is unavailable,
admission or cancellation can return `OUTCOME_UNKNOWN` with the existing job ref;
refresh/retry that same intent rather than inferring rollback.

Aggregate statuses include `queued`, `running`, `succeeded`, `failed`,
`partially_succeeded` and `cancelled`. Inspect current item codes as well as the
aggregate; cancellation or expiry after some commits can be `partially_succeeded`.
A persisted business success remains success after a host post-commit callback
warning. Do not create a fresh approval assuming that warning rolled it back.
Work can remain pending or need reconciliation after the business item succeeds;
database durability and lease fencing do not prove downstream exactly-once effects.

This is a bounded fixed-manifest implementation, not completion of the full batch
roadmap. All-filtered/10,000-target manifests, global operations, custom CRUD
replacement, a full job center, retention and general reconciliation remain
planned. AI/Surface dispatch and real-provider validation remain separate work.
All full release Gates remain open.

## Next Steps

* [Fixed Selections]({% link _core_features/selections.md %}) explains exact target identity and capture expiry.
* [Operations]({% link _core_features/operations.md %}) explains the shared per-record handler and transaction contract.
* [Durable Outbox]({% link _advanced/durable-outbox.md %}) separates business success from external delivery.
* [Development Status]({% link _reference/development-status.md %}) records the remaining product scope.
