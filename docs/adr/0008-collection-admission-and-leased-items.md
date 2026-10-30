# ADR 0008: One collection approval, independent leased item transactions

Status: implementation decision; owner review and full release gates remain open.

## Decision

A `scope: :collection` registration applies the existing per-target Operation
handler to one fixed Selection, with asynchronous admission and independently
committed items. The current target bound is 100. Global operations, custom CRUD
replacement, 10,000-target materialization and a full job center remain later work;
this intermediate implementation does not reduce the final plan.

The parent OperationRun alone consumes human confirmation. In one transaction it
binds owner/tenant/security epoch, registered operation/version, canonical typed
input, exact selection ID/manifest digest and independent execution deadline,
creates unique child intents and BatchItems, and records an admission audit.
Admission changes no business rows. One bounded wire payload (4 KiB) is persisted
on the parent; children bind its digest and carry no independent approval fields.
These payloads require host privacy/retention review and must not carry credentials.

Proposal preflight runs outside the parent lock, with per-handler and aggregate
30-second cooperative checks and a 256 KiB preview bound. Admission does not rerun
host preflight or project titles under that lock. It rechecks exact metadata,
current scope/show/versions, class/record command/input grants and digests before
consuming approval. The ordinary scope and policy calls must themselves remain
pure and bounded. None of these checks hard-interrupts arbitrary Ruby or SQL.

## Shared execution and fencing

A host-scheduled pending scan recovers lost enqueue and expired leases. Optional
`collection_auto_dispatch` is only an after-commit accelerator. One parent has at
most one live in-flight item. Each claim has an owner, increasing generation and
finite lease; retry attempts and execution time are bounded by the handler's
registered contract. A new attempt retains its stable child intent and target.

The internal `Operations::Runner#execute_admitted` requires a server-created Claim.
Inside the item transaction it locks parent/item, verifies consumed approval,
manifest membership, current context/epoch, current collection-level grants, then
uses the same Runner's scoped record/input/version/handler/audit/outbox/receipt
path. Public member preparation/execution refuses collection parents and children.
Workers do not synthesize `human_confirmed: true`. Normal handler transactions may
join the framework transaction; `requires_new` handler savepoints remain forbidden.
The collection admission/cancel/claim/execute entry points refuse an existing host
outer transaction so their reported result belongs to their own durable commit.

Safe receipt projection and completion metadata precede a final lease/deadline
check before leaving the transaction. Failure result/audit finalization also holds
parent/item locks, verifies owner/generation and checks the lease after writes.
An expired/stale result rolls back; a fenced job stops taking further items.
This protects database receipts, not irreversible external effects inside Ruby.
Domain callbacks must stay database-only; declared Work follows business commit.

## Authority, cancellation and results

Workers resolve fresh host authority for every item, without a system fallback.
Collection-level command/input authorization and per-record authorization are both
required. Revoking a class-level grant stops remaining work. The already consumed
Selection permission/approval TTL is not reused as execution authority; an explicit
execution deadline bounds unstarted work. Current target versions and business
rules are checked at execution.

`cancel_operation?` is separate and default-deny. Cancellation and item execution
serialize on the parent lock: cancellation first prevents a claimed but unstarted
item from writing; an item that commits first retains its business result, audit,
receipt and Work. Cancellation of a proposed parent prevents admission. Replaying
a previously admitted then cancelled parent reads the same cancelled run, without
resurrecting work. Partial success is explicit and never described as batch rollback.
Cancellation has its own audit record.

Parent receipt access uses a separate class-level grant. Job detail resolves only
currently scoped, show/receipt-authorized item labels and field access; hidden rows
stay hidden. Work statuses need current delivery permission and remain separate
from business status. Job views expose no parent payload or old preview values.
Unknown commit observation returns OUTCOME_UNKNOWN with the same job reference;
recovery checks/retries that intent rather than admitting another one. Callback
warnings preserve proven committed results.

The native no-JavaScript flow is selection, input, review, explicit queue, then
owner/tenant job detail with refresh and cancel. The basic list is bounded to 50
recent accessible runs. It is not general cross-owner job management, reconciliation
or retention tooling. All remaining product/release gates continue to apply.
