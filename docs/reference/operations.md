# Operation contract (development)

The current execution boundary is `RailsAiAdmin::Operations::Runner` for default
CRUD and registered synchronous member operations. `RailsAiAdmin::Collections::Runner`
adds parent approval and durable asynchronous execution of the same per-record
handler over an exact bounded Selection. A durable outbox separately delivers one
declared external effect for a committed operation. Global/custom CRUD operations,
all-filtered/10,000-target manifests, a full job center/retention workflow, Chat and
Surface adapters remain unimplemented. The full development plan and release
Gates remain required.

## Prepare and execute

Given current authenticated `context`, registered `CustomerAdmin` and a scoped
`customer`:

```ruby
runner = RailsAiAdmin::Operations::Runner.new
intent = runner.prepare(
  context: context, resource: CustomerAdmin, operation: :update,
  target_id: customer.id, expected_version: customer.lock_version,
  input: { "name" => "Reviewed name" }
)
result = runner.execute(
  context: context, intent_ref: intent.id,
  input: { "name" => "Reviewed name" },
  human_confirmed: true, origin: :ui
)
```

Only trusted host code supplies `human_confirmed`. It must represent a deliberate
human form/confirmation event; it is never authority supplied by a model or client
parameter. Origin (`ui`, `surface`, `assistant`) is audit metadata. Accepting a
metadata value does not expose an implemented Surface or Assistant adapter.

For default CRUD, omitting `input` in preparation creates an editable form intent. The deliberate
Save binds input and consumes confirmation in the same transaction as the business
write. Supplying input creates a proposal bound to its canonical digest; changed
input requires a new intent. Preparation does not execute domain validation/save
callbacks. Normal create/update uses the Save event; delete uses a separate
consequence/target confirmation page.

## Custom member handlers

A resource registers a distinct custom key:

```ruby
operation :triage, handler: "TriageTicketOperation",
  scope: :member, confirmation: :required
```

The handler inherits `RailsAiAdmin::Operation`, declares `input` using the scalar
Field DSL, and implements `perform(context, record, input)`. Input is a typed hash
with string keys. `version` defaults to `"1"`, `description` to a class-derived
label and `max_duration` to five seconds (at most 30). `atomic_models` contains
additional model class-name strings whose pools must match the operation pool.
A readonly resource or disabled custom action cannot admit its write command.
`scope: :collection` uses the same handler contract through the separate Collection
Runner below; public member preparation/execution cannot execute it or its children.

`preflight(context, record, input)` returns proposed values by resource field name.
The framework supplies readable original values, filters the returned fields and
coerces the proposed values. The handler must neither save nor mutate its target.
The custom preflight read-only guard covers scoped lookup, authorization, input
grants/coercion and the preview handler. Its server intent is created after leaving
that guard. Active Record `while_preventing_writes` does not sandbox trusted Ruby,
raw connections, filesystem or external calls. Host review/tests still establish
purity across this whole path. The handler can also return `invalid(...)` or
`conflict` rather than a changes hash to reject a proposal.

`Runner#preflight` takes the prepare arguments and returns
`Runner::Proposal(intent, values, changes)` on valid admission, or a typed
`Operations::Result` for handled input/timeout failures. Authorization and
configuration can raise. Other ordinary custom-preflight exceptions become generic
`OPERATION_FAILED`, without the original diagnostics in the framework HTTP/log
output. The framework cannot suppress explicit logging performed by host code.
`prepare` returns the proposal's intent or raises on a handled failure. Custom operations require non-nil input-bound preflight;
ordinary unbound CRUD form-intent behavior cannot be used for custom commands.

A custom handler persists its original scoped target and returns `success(record)`,
`invalid(*operation_input_fields)` or `conflict`. It cannot return another target,
leave unsaved changes, destroy the target or return an arbitrary object. Error
fields are intersected with permitted operation inputs before display. Normal
Active Record validations/callbacks still apply. If the target's persisted
attributes actually change, its `lock_version` must advance; bypassing that version increment rolls the operation back with
`ConfigurationError`. Handler errors before commit roll back the
domain/receipt/audit/outbox; callback errors after commit cannot undo a durable
success.

### Independent grants

| Capability | Custom adapter | Pundit policy |
| --- | --- | --- |
| Command | `allowed?(context:, action:, resource:, record:)` | Registered operation's predicate, such as `triage?` |
| Typed operation inputs | `operation_fields(context:, resource:, operation:, record:)` | `permitted_operation_fields(operation)` |
| Committed custom receipt | `read_operation_receipt?(context:, resource:, operation:, record:)` | `read_operation_receipt?(operation)` |
| Post-commit effect | `deliver_work?(context:, resource:, operation:, work_kind:, record:)` | `deliver_operation_work?(operation, kind)` |
| Cancel collection remainder | `cancel_operation?(context:, resource:, operation:)` | `cancel_operation?(operation)` on model class |

Operation input grants do not come from ordinary `:write` fields. Missing grants
deny; required schema inputs must all be permitted. Custom receipt reads use
independent receipt authorization, not the original command predicate. A command
whose own transition changes its precondition can therefore return its original
receipt without being admitted again. Before success, current operation-input
grants remain mandatory. For a successful custom receipt, replay coerces against
the complete bound typed operation schema to compare its digest, without asking
for current `operation_fields`. Any replay coercion failure or changed input is
generic `IDEMPOTENCY_CONFLICT` with empty field errors; it does not identify
unadmitted/hidden fields. Current scope, identity/security version, contract
fingerprint, expiry, receipt grant and safe field projection still apply. Receipt
authority grants no extra record values or Work delivery permission.

### Native HTTP flow

Paths relative to the mount are:

| Request | Result |
| --- | --- |
| `GET /:resource/:id/operations/:operation` | Permitted-input form; no admitted intent yet |
| `POST /:resource/:id/operations/:operation/preflight` | Pure preview and input-bound intent |
| `POST /:resource/:id/operations/:operation/execute` | Human confirmation through the shared Runner |

Preflight accepts `input[...]` and `expected_version`. Confirmation carries the
server intent ref and the reviewed typed input serialized as `confirmed_input`;
that JSON string is bounded to 16 KiB. Altering it does not alter the bound intent.
Editing input requires another preflight. The operation endpoint binds resource,
operation and target; UI controls alone grant no permission. `origin` is audit
metadata, not an alternate authority.

Native preflight renders a Turbo Stream confirmation for Turbo requests and an
ordinary HTML confirmation without JavaScript. Successful execution uses HTTP 303.
The engine loads the `turbo-rails` server integration explicitly. Minimal hosts
using all Rails frameworks must also configure Action Cable for their environment;
the packaged test hosts use its test adapter. This does not enable a durable
broadcast transport or admin streaming feature.

## Identity, locking and transaction

Server-issued UUID intent refs bind actor, tenant, host security version, resource,
operation/schema version, exact target, expected record version, digest and expiry.
HTTP controllers additionally bind the endpoint's resource, operation and target.
Unknown/expired client refs cannot recreate work. The host changes security version
on authority changes. Each attempt uses the appropriate current command/receipt
authorization and output projection; successful custom replay uses the bound-input
schema rule above instead of a fresh operation-input grant.

Domain records, `OperationRun`, `AuditEvent` and `WorkItem` must share one writable
connection pool. The runner locks the intent before the domain record and uses a
framework transaction/savepoint. Domain callbacks may not create irreversible external
side effects. Matching database addresses from different pools are refused.
Successful domain write, confirmation, receipt, audit and outbox intent commit
atomically. A committed Work ref does not mean its external effect has completed.
A successful result inside a caller's outer transaction is not durable until the
outer transaction commits.

Generic writes require standard `lock_version`, a single primary key and a
supported SQLite/PostgreSQL adapter. No custom locking column, composite key,
shard or cross-pool atomicity is promised. MySQL is unsupported. Callback vetoes
and `Rollback` do not become successful receipts. A failed audit rolls back the
business write and its new outbox items. Failures/rejections have separate audit status.

Additional declared `atomic_models` are validated for the same pool, but this
does not authorize, scope or lock their records or discover undeclared writes.
A normal same-pool `transaction` that joins the framework transaction is allowed.
Custom handlers may not open `requires_new`; nested savepoints on the operation
connection are rejected. External effects belong after commit.
`max_duration` checks are cooperative before/after handler execution: they do not
hard-interrupt arbitrary Ruby or SQL. A detected pre-commit timeout rolls back;
this is not a hard execution sandbox.

The operation fingerprint includes physical model/table/primary-key identity,
resource policy mapping and operation definition/version/schema. Changed contracts invalidate existing development
form/proposal intents. Method bodies are not automatically hashed; bump versions
deliberately when semantics change. Reopen the
form and review the latest permissions rather than editing persisted evidence to
force a retry. The fingerprint does not replace current policy/field checks.

## Replay and current visibility

A same-intent/same-normalized-input committed retry returns its receipt and a
current authorized projection, without a repeated domain save/callback. It does
not replay a historical field snapshot. A same-intent/different-input committed
retry yields `IDEMPOTENCY_CONFLICT`; a changed bound proposal before execution
yields `APPROVAL_INVALIDATED`. Two deliberately separate intents do not deduplicate
by digest alone. The record version check applies before the original execution,
not as a reason to rerun a committed retry.

Current record scope, identity/security version and visible-field permissions
still apply on replay. Default CRUD rechecks its action; successful custom
operations use the explicit receipt grant instead of the command's precondition
and compare input against the bound complete schema rather than current
operation-input grants. Failed/changed replay input gives only generic
`IDEMPOTENCY_CONFLICT` with no field errors. A
revoked or cross-tenant caller does not regain data from an old receipt. A blind
write can return success with no projected values. A deleted record has no current
projection; returning its receipt requires a current collection-level destroy grant.
SQLite contention can produce `CONFLICT`; retry the same valid intent rather than
create an independent business intent. Intent retention/purge scheduling is not
yet implemented. Do not delete receipts inside the supported retry window.

## Result and post-commit failures

`Operations::Result` exposes `code`, `status`, `success?`, `retryable?`, `record_id`,
`audit_ref`, `values`, `errors`, `replayed`, `warning` and `work_refs`. It never returns a domain
Active Record object. Current error codes include `NOT_FOUND`, `UNAUTHENTICATED`,
`VALIDATION_FAILED`, `CONFLICT`, `APPROVAL_REQUIRED`, `APPROVAL_EXPIRED`,
`APPROVAL_INVALIDATED`, `IDEMPOTENCY_CONFLICT`, `TIMEOUT` and `OPERATION_FAILED`.
Misconfiguration raises
`ConfigurationError` rather than pretending to be a valid write.

A callback may raise after the database commit. The business receipt remains
successful; the executor records `POST_COMMIT_CALLBACK_FAILED` as a separate run
warning, returns it with the successful result and retains it on replay. Do not
create a fresh intent believing the domain write rolled back. Reconcile the host
callback and any external consequence. A process death before warning capture or
an external request in flight still requires host recovery; this slice does not
claim a complete external-effect reconciliation protocol.

The audit keeps refs, result codes and changed field names, not raw input,
full before/after values or arbitrary validation messages. Append-only behavior
applies to the normal model API, not database administrators or direct SQL.

## Durable outbox registration and input

`config.work_handlers` maps stable string kinds to Work class-name strings.
`config.outbox_auto_dispatch` defaults to false. A handler inherits
`RailsAiAdmin::Work`, reuses `Operation.input` and implements `perform(ctx, input)`.
It delivers a committed fact, not an asynchronous domain command. Its defaults
are non-idempotent, 60-second lease, three attempts, one-day lifetime and
`record_version_policy :exact`.

Inside a custom operation, `ctx.outbox.enqueue(kind, key: kind, input: ...)`
(or keyword input attributes instead of `input:`) persists the declared typed
payload, its digest, handler fingerprint and deadline. It requires the active
operation transaction and does not call a queue or provider. Payload JSON is at
most 4096 bytes; work keys are bounded strings. A repeated operation-run/work-key
pair returns the same ref only if its kind/payload/handler contract matches.
Different payload under that same pair conflicts. `ctx.ref(record)` accepts only
the original scoped target. Payloads persist data; minimize them and do not put
credentials in this table.

The Runner stores the target's committed lock version on its Work items. Default
`:exact` stops a later changed target with `RECORD_CHANGED` and
`reconciliation_required`. Explicit `:current` is available for host-reviewed
workflows that safely use current state; it does not bypass delivery permission,
current scope/security version or the request-digest invariant. Handler changes
that alter the Work fingerprint stop delivery with `HANDLER_CHANGED`. Increment
handler versions for semantic code changes; fingerprints do not hash method bodies.

## Delivery authority and one effect

The configured context adapter must implement
`resolve_job(actor_ref:, tenant_ref:, security_version:)`. It reconstructs current
authority from trusted typed refs, freshly loads actor/tenant membership and uses
the current security version. The dispatcher compares the result with the run's
owner/tenant/version, requires its succeeded receipt, current operation contract,
current target scope and an independent delivery grant. No system-actor fallback
is supplied. Delivery is checked again immediately before the effect.

`Work#perform` must complete one `ctx.effect(request: actual_request_hash)` call.
No external effect may run in a database transaction. The actual semantic request
must be a plain JSON Hash: string/symbol keys that cannot collide after string
normalization; String, Integer, finite Float, boolean, nil, Hash and Array values;
maximum nesting depth eight and 16 KiB JSON. BigDecimal, Date, Time and other
typed objects must first be serialized by the host to the actual wire values
used by its transport. A dedicated `Outbox::RequestDigest` canonicalizes this
plain JSON, independently of the typed-input digest/marker algorithm. Its digest
is persisted before the external call. A retry with changed
request content under the same Work ID/key is blocked as `REQUEST_CHANGED`.
Only the delivery key `ctx.delivery_key` is stable across attempts/generations;
pass it to a downstream implementation that durably enforces it.

The boundary's block must return only for a known success and raise for an unknown
or failed effect. An unexamined returned HTTP 500 is not interpreted as failure by
the dispatcher. One item permits one effect block, but trusted Ruby can bypass
it; additional I/O/domain mutations outside this contract are prohibited host
behavior, not a sandboxed impossibility. Work handler execution, authorization
and the RPC/effect block run under `while_preventing_writes` for ordinary Active
Record writes. Only the framework's short CAS bookkeeping block temporarily
allows those writes. This is a protective guard, not a trusted-Ruby sandbox;
never use Work for unaudited domain updates or disable the guard in host code.

Work has its own deadline derived from admission and `max_age`. The already
consumed operation-intent TTL does not expire an admitted delivery; current
security/version/scope, record-version policy and its separate deadline still
apply. Approval is not reused to admit new targets or work after the fact.

## Scanning, leases and uncertain outcomes

`rails_ai_admin:work:scan` enqueues up to 100 due pending/expired-lease items through
Active Job; `rails_ai_admin:work:drain` visits up to 100 inline. The public
`Outbox::Dispatcher#scan_pending!(limit: 100, inline: false)` supports bounded scans;
`run(work_ref)` visits one item outside domain transactions. Hosts must provide a
recurring scan and a persistent queue where enqueue is used. No scheduler is
installed. Setting `outbox_auto_dispatch = true` only accelerates delivery after
commit; a missed enqueue or process crash is still recovered by scanning.

`Outbox::Dispatcher::Result` exposes `work_ref`, `status`, `code` and `success?`.
Work statuses include `pending`, `running`, `succeeded`, `cancelled`, `failed` and
`reconciliation_required`, independent of the successful OperationRun. Pending
items use bounded retries/backoff. Every claim assigns a lease owner and increasing
generation. The effect and receipt transitions check owner/generation and lease;
a stale worker cannot overwrite a newer owner's state. Fencing cannot recall an
already in-flight external request.

Before any effect starts, revocation may cancel unsent work without reversing the
business success. After an unknown effect, denial cannot assert definite
cancellation. Non-idempotent unknown outcomes are not automatically retried.
Declared-idempotent retries require real downstream support and reuse the same
key/request digest within attempt/deadline limits. Changed contracts/requests,
record-version mismatches and expired uncertain work require reconciliation.

A current owner's known success survives later local callback failure/revocation
and can retain `succeeded` with `POST_EFFECT_CALLBACK_FAILED`. Lost ownership is
reported as `FENCED` without rewriting a newer owner's pending/success receipt.
Process death after a remote success but before its durable receipt can still
leave an unknown outcome. Database durability, fencing and declared idempotency
are not downstream exactly-once proof. Reconcile with the actual downstream
system; do not edit state or create fresh keys assuming nothing happened.

This slice adds no general reconciliation UI, general-purpose asynchronous workflow
engine, Chat/Surface delivery or external-provider guarantee. Full roadmap/release
Gates remain required. See `docs/adr/0006-custom-operations-and-outbox.md` and the
public Durable Outbox guide for the current boundaries.


## Fixed-manifest collection review and admission

Register a distinct custom key with `scope: :collection` and an `Operation` handler
class-name string. It remains a per-target `preflight(ctx, record, input)` /
`perform(ctx, record, input)` handler; collection execution is always asynchronous.
A Selection contains at most 100 explicit canonical IDs/versions. Capture is
metadata-only and creates no OperationRun/audit/job or human approval.

Given a live Selection and current context:

```ruby
collections = RailsAiAdmin::Collections::Runner.new
proposal = collections.preflight(
  context: context, resource: CustomerAdmin, operation: :award_points,
  selection_ref: selection.selection_ref, input: { "amount" => "8" }
)
raise proposal.code if proposal.is_a?(RailsAiAdmin::Collections::Result)
```

This example requires a registered collection `:award_points` handler with required
integer `:amount`; the public Collection Operations guide supplies its complete
resource/handler example. The return is `Collections::Runner::Proposal(intent,
values, targets)` or a handled `Collections::Result`. Targets have `id`, current
permitted `label` and readable `changes`. Configuration failures can raise. Lookup,
authorization, input and handler preview use the ordinary Active Record read-only
guard, not a trusted-Ruby sandbox. The entire preview path must remain pure.
Proposal preflight runs outside the parent lock with a cooperative aggregate
30-second budget as well as each handler max_duration; it does not hard-interrupt
Ruby or SQL.

Preflight revalidates Selection ownership/epoch/expiry/contract/exact target
versions and current selection/index/show/scope/read grants. It checks command and
operation-input grants at class level, then for every target through the shared
Runner preview. Custom adapters receive `record: nil` at class level; Pundit uses
the explicitly mapped policy with the model class. Required inputs must be granted
at each applicable boundary. The parent binds the exact ID/version manifest,
Selection digest, operation/resource fingerprint, input digest, owner/tenant/epoch,
origin and approval expiry.

The parent stores normalized typed wire input once, at most 4 KiB; preview changes
are bounded to 256 KiB. Selection rows remain metadata-only. Input payloads are
not copied to child intents or audit/job views. Exclude secrets/credentials and
review host SQL/debug/application logging independently of framework redaction.

After deliberate human review only:

```ruby
admitted = collections.admit(
  context: context, intent_ref: proposal.intent.id,
  input: proposal.values, human_confirmed: true
)
raise admitted.code unless admitted.accepted?
```

Native handling additionally supplies `binding: { resource_key:, operation:,
selection_id: }` to bind the endpoint. Admission locks the parent, verifies
approval input and the still-live Selection metadata/digest, exact scope/show/
versions and current class/per-target command/input grants. It consumes approval
without repeating host preflight or title projection under the lock, then
atomically creates its child intents/BatchItems, parent confirmation and admission
audit. It performs no business mutation. The parent owns the only human approval;
children have no independent confirmed/approved fields. Public member/child
execution is rejected; only a server-created admitted lease can enter the shared
Runner worker boundary. Lease claims are not public HTTP authority.

Same-parent/same-input admission replay returns the existing job with `replayed:
true`. It requires current parent receipt permission and checks the complete bound
typed schema/digest, not fresh operation-input grants or command preconditions.
Failed coercion or changed input gives generic `IDEMPOTENCY_CONFLICT` without
field errors. Proposed/unexecuted work still needs current command/input grants.
Separate parent intents do not deduplicate by digest alone.

`Collections::Result` exposes `code`, `job_ref`, `status`, `errors`, `replayed` and
`warning`. `accepted?` means a queued/existing job was accepted; `success?` means
the aggregate status is `succeeded`. Admission's `QUEUED` is not business success.
If admission commit/read recovery cannot establish the durable outcome,
`OUTCOME_UNKNOWN` returns the same job_ref with status `unknown`. Check the job
and retry the same intent/input rather than issuing new approval. A known
committed receipt remains preserved.

## Collection item transactions, deadlines and cancellation

`Collections::Dispatcher#run(job_ref, limit: 100)` visits at most 100 items outside
any existing database transaction. It claims one live item per parent at a time,
assigning a lease owner and increasing generation. The worker calls host
`resolve_job(actor_ref:, tenant_ref:, security_version:)` to reconstruct fresh
authority; it compares current owner/tenant/epoch with the approved parent. There
is no system-actor fallback.

The internal shared Runner transaction locks parent/item, verifies approved
manifest and child identity, current class-level (`record: nil`) and per-record
command/input grants, exact target version, lease owner/generation/expiry and
execution deadline. Class-level command/input revocation returns
`AUTHORIZATION_REVOKED` and stops remaining work. Execution does not reconsume the
Selection or require select_records? again. Target mutation, audit,
receipt, optional outbox intent, item success and parent aggregate commit
atomically. A final lease/deadline check follows output projection and item
metadata before transaction exit. Failure-audit metadata also has a final lease
check, and a stale job stops before another claim. A stale owner cannot finalize
a newer generation. Each item commits
independently, so a later failure does not undo an earlier success. Declared
`atomic_models` still require one pool and host-owned scoping/locks. Standard
joining transactions are allowed; handler `requires_new` is rejected. Persisted
attribute changes must advance `lock_version`, just as in member execution.

Domain, OperationRun, AuditEvent, WorkItem, BatchItem, Selection and SelectionItem
must share one SQLite/PostgreSQL pool with a single primary key and standard
`lock_version`. No cross-pool atomicity, MySQL or composite-key support is added.
External effects belong in declared post-commit Work, not the item transaction.

| Operation setting | Default | Collection constraint |
| --- | --- | --- |
| `max_duration` | 5 seconds | Positive and at most 30 seconds |
| `lease_duration` | 60 seconds | 5..3,600 seconds and greater than max_duration |
| `execution_window` | 1 hour | 60 seconds..7 days |
| `max_attempts` | 3 | Integer 1..10 |

Approval/Selection expiry controls admission. An admitted job has its own
execution deadline; consuming approval does not make the job depend on the old
intent TTL. Deadline expiry stops remaining work. Handler duration/deadline checks
are cooperative, not a hard interrupt for Ruby/SQL. Ordinary handler errors may
retry with bounded backoff within attempts/deadline; validation/version conflicts
are not fresh approval.

`Runner#cancel(context:, job_ref:)` requires the independent class-level
`cancel_operation?` grant as well as parent ownership/current epoch/contract.
Cancelling a proposed parent blocks admission. Cancelling an admitted run stops
uncommitted items and preserves every committed target, receipt, audit and Work.
Cancellation and item commit serialize on the same parent lock. Terminal status
is retained. Cancellation is not rollback or downstream effect recall.

Current aggregate statuses include queued/running/succeeded/failed/
partially_succeeded/cancelled. Inspect item codes, too: expiry or cancellation after
some successes can leave a partially_succeeded aggregate. Known committed success
survives post-commit callback warnings. Business success and Work delivery remain
separate; outbox scans/delivery permissions and downstream idempotency are still
required, and database durability is not downstream exactly-once proof.

## Collection recovery and native receipts

`config.collection_auto_dispatch` defaults to false. Enabling it adds an
after-commit Active Job enqueue accelerator only. Hosts must provide a persistent
queue and recurring `rails_ai_admin:collections:scan`; `collections:drain` visits
up to 100 due runs inline. `Dispatcher#scan_pending!(limit: 100, inline: false)`
accepts 1..1,000 and recovers queued/expired-lease items after queue loss or process
death. Work delivery has its own scan; collection workers do not deliver it.

The no-JavaScript native flow is Selection preview -> collection input -> pure
review -> explicit Confirm and queue -> HTTP 303 job detail. Relative paths are
`GET /:resource/operations/:operation`, POST to its `/preflight` and `/execute`,
`GET /jobs/:job_ref` and CSRF-protected `POST /jobs/:job_ref/cancel`. `GET /jobs`
lists up to 50 recent accessible owner/tenant/epoch runs; this is not a full job
center, scheduler or retention system.

`Collections::Queries#fetch(context:, job_ref:)` returns current receipt metadata,
counts and permitted entries. Parent reads use class-level receipt permission;
entries use current record scope/show/receipt/read grants, not the command's
old precondition. Hidden records are omitted and hidden title fields become
`Record #id`. Work status visibility also needs its independent delivery grant.
Input payloads and historical before/after snapshots are not returned. `recent`
uses the same current owner/tenant/epoch/receipt boundary. Full global/batch,
10,000-target manifests, retention, general reconciliation and AI/Surface work
remain in the plan; this slice closes no full release Gate.
