# Architecture

Status: foundation implementation; API may change before release.

The isolated `RailsAiAdmin::Engine` owns admin routes and execution evidence.
The host owns authentication, SQL policy scopes, domain models and services.
Resources explicitly declare exposed scalar fields. Field declarations never
widen a policy decision. Readonly virtual fields compute from declared scalar
snapshots only when their own and all recursive dependency grants survive. A
bounded acyclic graph and per-projection cache preserve the read boundary; model
getters/computations prevent ordinary AR writes, without sandboxing trusted Ruby.
No arbitrary constant, SQL or template comes from input.

A host context adapter returns a fresh `Context` for each request. References
include the `raa:` namespace, object type and key. There is no mutable global
Current context. Configuration stores host class names and freezes after boot;
Rails `to_prepare` replaces resource, Operation and Work registries after reload.

Conventional host presentation uses normal Rails view precedence and an explicit
single-template override catalog. Source/context headers and bounded doctor checks
identify upgrade drift without executing ERB or certifying host edits. Templates
remain trusted Ruby; authority stays in the Context/Access/Runner boundary.

All business writes use the operation runner. Domain records, intents, audit and
outbox rows share one Active Record connection pool. Default CRUD and explicitly
registered member Operations use that boundary, typed inputs, current grants,
human intent evidence and `lock_version`. Intents bind stable model/table/primary-key
identity; remapping those IDs invalidates old intents rather than redirecting them. Custom writes that change the target
must advance its version. Host Ruby and callbacks are trusted code; declaration
checks and ordinary AR guards do not create a plugin sandbox.

Custom input-bound preflight feeds a native confirmation page. Independent
receipt authority permits a successful replay after the command's business
precondition stops being true, while current read/scope rules still constrain
output. Invalid committed replays disclose no input schema details.

Outbox delivery follows commit. Every attempt reconstructs job identity and uses
independent delivery authority. Finite leases, owner/generation fencing and stable
keys protect the framework's receipts. One explicit effect per item binds a plain
JSON request fingerprint; ordinary AR business writes are prevented in delivery.
Idempotent replay still requires downstream cooperation. Non-idempotent unknown
outcomes and incompatible queued work remain for reconciliation. Host-scheduled
pending scans close the after-commit/queue-loss window. Delivery is distinct from
the already committed business result. See ADR 0006 and the operation contract.

Fixed Selections capture at most 100 distinct canonical IDs and lock versions.
Immutable manifest rows retain owner/tenant/security epoch, stable model/table/key
identity, digest and expiry; they retain neither a query to expand later nor labels.
Current scope/show/field and independent selection authority apply on every view.
Joined scopes are deduplicated by authorized primary keys inside SQL before the
outer bound. Selection capture creates no approval, business run, audit or work.
Collection admission binds that exact digest, typed inputs and operation version.
One parent OperationRun consumes human approval atomically with child intents and
BatchItems. It stores one bounded wire payload and the approved fixed manifest;
children carry no independent human approval. Workers resolve current authority
and recheck collection-level and per-record command/input grants. Public member
execution refuses parent/child collection intents.

Each item holds the parent/item locks, uses the existing Runner domain/audit/
receipt/outbox transaction, then performs a final lease/deadline check after safe
projection and completion metadata. Failure receipts/audits are fenced too. A
parent has one live in-flight item; cancellation serializes on that parent and
retains already committed items and Work. Approval TTL constrains admission,
while an independent deadline constrains execution. Pending scans recover lost
queues and expired leases. These entry points must own their transaction.
Native collection review, explicit queueing and current-authority job views use
these same boundaries; they do not provide a separate business executor.

Global actions, custom CRUD replacement, 10,000-target materialization, a full
job/reconciliation center, cross-pool atomicity and external calls in domain transactions remain
unimplemented/unsupported; they remain requirements in the full plan.

RubyLLM and rails_tool_views are bounded runtime dependencies. Conventional boot
must not load the experimental adapter, require AI tables or call a provider.
Chat/Surface integration remains a separate milestone, using the same authority.
See docs/adr and docs/reference/public-contract.md.
