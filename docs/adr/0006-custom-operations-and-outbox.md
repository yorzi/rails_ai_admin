# ADR 0006: Member operations and a durable delivery outbox

Status: implementation decision; owner review and full release gates remain open.

Follow-up: ADR 0008 implements the bounded collection admission/item-execution
path described here. Earlier unsupported-slice statements below record this
original decision; global operations, larger manifests and full job/retention
work remain open.

## Decision

Implement synchronous member-level custom `Operation` handlers through the same
Runner as conventional CRUD. The host registers a handler by class-name string,
keeps business data and authority, and declares typed inputs using the existing
Field/InputSchema implementation. All custom operations require a separate human
confirmation after input-bound preflight. Collection/global operations, CRUD
handler replacement, asynchronous business execution, AI and Surface adapters are
outside this implementation slice.

A custom adapter grants the operation action and its `operation_fields`
independently of ordinary attribute writes. Pundit maps a registered action to its
predicate and inputs to `permitted_operation_fields(operation)`. A separate
`read_operation_receipt?` permission authorizes a committed receipt: replay must
not require the original command precondition to remain true after its own state
transition. Uncommitted intents still require current operation-input grants.
Successful custom receipt replay instead uses the full bound typed schema to
compare input digests, without requiring current `operation_fields`. Coercion
failure or changed replay input yields only `IDEMPOTENCY_CONFLICT` with no field
errors. Current SQL scope, identity/security version, contract/expiry/receipt
binding and visible field projection still apply. Delivery uses its own `deliver_work?` grant,
or Pundit's `deliver_operation_work?(operation, kind)`; permission to execute a
command is not implicit permission to deliver any later effect.

## Preflight and transaction boundary

Preflight returns proposed values by resource field name. The framework supplies
and filters readable before/after projections and coerces the proposed values.
Custom scoped lookup, authorization, input resolution and the handler all run
under Active Record `while_preventing_writes`, before the intent row is created;
target mutation is rejected. Ordinary exceptions outside ConfigurationError and
AccessDenied become safe `OPERATION_FAILED` results without leaking their original
HTTP/framework-log diagnostics. Explicit host logging remains outside this
boundary. The guard does not sandbox trusted Ruby, prevent arbitrary
network/filesystem work or prove purity. Hosts review and test the full path.

The Runner owns intent claim, target lock, current policy/version checks,
confirmation consumption, domain save, audit, receipt and WorkItem insertion.
These rows and the target use one connection pool. `atomic_models` explicitly
lists additional host models for same-pool validation; it does not grant access,
automatically scope/lock additional records or discover every model arbitrary Ruby
might touch. The host remains responsible for those invariants. A custom handler
must persist its original target and return `success(record)`, `invalid(...)` or
`conflict`. It may not replace the target with another record or destroy it. If
persisted target attributes change, lock_version must advance; otherwise the
framework rolls back with ConfigurationError.

Ordinary same-pool transactions may join the framework transaction. Handlers must
not open `requires_new` transactions. The framework detects nested
savepoints on its connection and rejects the operation, rolling back the domain
transaction. Additional connections and external effects remain prohibited host
behavior. `max_duration` is a soft check around handler execution, not an interrupt
for arbitrary Ruby or SQL. A deadline violation before commit rolls back and
returns a controlled timeout; a callback failure after durable commit preserves
the successful business receipt and its separate warning.

## Persist delivery intent before enqueueing

`ctx.outbox.enqueue(kind, key:, input:)` persists a typed, bounded payload and its
digest in the domain transaction. Work kind/class-name mappings are explicit
`config.work_handlers`. Uniqueness is scoped by operation run and stable work key;
reusing that pair with a changed kind, payload or handler fingerprint conflicts.
Committed operation results return Work refs, not proof that delivery completed.

`Work` reuses the Operation input DSL and implements `perform(ctx, input)`.
One Work item permits one declared external effect through
`ctx.effect(request: actual_request_hash)`. The handler/transport must execute the
request represented by that hash, signal unknown/failure by raising, and pass the
stable `ctx.delivery_key` to a downstream system that actually honors it. The
framework stores the external request digest before the effect so a later attempt
cannot change the body/target under the same key. A request must be a plain JSON
Hash with noncolliding normalized string/symbol keys, supported JSON scalar/container
values, finite floats, depth at most eight and JSON size at most 16 KiB. The host
serializes BigDecimal/Date/Time to its real wire values first. Dedicated
RequestDigest handling is separate from typed input marker-based digests.
Payloads are durable JSON, not secret storage; hosts minimize them and resolve credentials through their own
protected configuration. Ordinary Active Record writes in Work authorization,
handler and RPC/effect execution are prevented; only short framework CAS
bookkeeping allows writes. This is not a trusted-Ruby sandbox and does not make
Work an allowed path for unaudited domain updates.

Default `record_version_policy :exact` binds delivery to the target's committed
version. Later changes stop delivery for reconciliation. A host can explicitly
select `:current` for a workflow that safely uses current state, without bypassing
current identity/scope/delivery authorization or external request-digest checks.
Work has its own deadline after admission; consuming an operation approval does
not extend approval to new targets, while expiry of the consumed intent TTL does
not itself cancel already admitted Work.

## Recovery and fencing

`outbox_auto_dispatch` defaults to false. Optional after-commit enqueue is only an
accelerator; the pending row survives an enqueue outage or process death. Hosts
must schedule recurring `rails_ai_admin:work:scan` using a persistent queue, or
`rails_ai_admin:work:drain` for bounded inline delivery. No recurring scheduler is
installed. Both tasks visit at most 100 due items by default; repeated scans also
recover expired leases.

Each claim has a lease owner and increasing generation. The effect boundary and
receipt updates verify ownership/generation so an old worker cannot overwrite a
new owner's state. Fencing cannot recall an external request already in flight.
Non-idempotent unknown outcomes are not automatically retried; they require
reconciliation. Idempotent retries require truthful downstream support and reuse
the same stable key/request digest. A known successful effect is not reclassified
as unsent merely because a subsequent host callback fails or authority is revoked.
A stale response remains fenced and cannot rewrite the newer owner's receipt.

Database durability and worker fencing do not establish downstream exactly-once
execution, production recovery or a provider guarantee. Real consumer, concurrency,
crash and downstream tests remain distinct evidence, and complete Gates A–E remain
required. Changing operation or work semantics requires a version bump and review
of persisted intents/items; fingerprints are not automatic hashes of method bodies.
