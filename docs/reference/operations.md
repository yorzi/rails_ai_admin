# Operation contract (development)

The current public execution boundary is `RailsAiAdmin::Operations::Runner` for
synchronous database-only `create`, `update` and `destroy`. Custom handlers,
asynchronous work, batch operations, Chat and Surface adapters are not implemented.
The broader operation DSL in the development plan remains a design target.

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

Omitting `input` in preparation creates an editable form intent. The deliberate
Save binds input and consumes confirmation in the same transaction as the business
write. Supplying input creates a proposal bound to its canonical digest; changed
input requires a new intent. Preparation does not execute domain validation/save
callbacks. Normal create/update uses the Save event; delete uses a separate
consequence/target confirmation page.

## Identity, locking and transaction

Server-issued UUID intent refs bind actor, tenant, host security version, resource,
operation/schema version, exact target, expected record version, digest and expiry.
HTTP controllers additionally bind the endpoint's resource, operation and target.
Unknown/expired client refs cannot recreate work. The host changes security version
on authority changes; every attempt also rechecks the current policy and field list.

Domain records, `OperationRun` and `AuditEvent` must share one writable connection
pool. The runner locks the intent before the domain record and uses a framework
transaction/savepoint. Domain callbacks may not create irreversible external
side effects. Matching database addresses from different pools are refused.
Successful domain write, confirmation, receipt and audit commit atomically.
A successful result inside a caller's outer transaction is not durable until the
outer transaction commits.

Generic writes require standard `lock_version`, a single primary key and a
supported SQLite/PostgreSQL adapter. No custom locking column, composite key,
shard or cross-pool atomicity is promised. MySQL is unsupported. Callback vetoes
and `Rollback` do not become successful receipts. A failed audit rolls back the
business write. Failures/rejections have separate audit status.

The operation fingerprint includes the explicit resource policy mapping. A
changed mapping invalidates existing development form/proposal intents. Reopen the
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

Current action, record scope and field permissions still apply on replay. A
revoked or cross-tenant caller does not regain data from an old receipt. A blind
write can return success with no projected values. A deleted record has no current
projection; returning its receipt requires a current collection-level destroy grant.
SQLite contention can produce `CONFLICT`; retry the same valid intent rather than
create an independent business intent. Intent retention/purge scheduling is not
yet implemented. Do not delete receipts inside the supported retry window.

## Result and post-commit failures

`Operations::Result` exposes `code`, `status`, `success?`, `retryable?`, `record_id`,
`audit_ref`, `values`, `errors`, `replayed`, and `warning`. It never returns a domain
Active Record object. Current error codes include `NOT_FOUND`, `UNAUTHENTICATED`,
`VALIDATION_FAILED`, `CONFLICT`, `APPROVAL_REQUIRED`, `APPROVAL_EXPIRED`,
`APPROVAL_INVALIDATED` and `IDEMPOTENCY_CONFLICT`. Misconfiguration raises
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
