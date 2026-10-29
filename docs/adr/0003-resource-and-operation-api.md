# ADR 0003: Typed scalar resources and a single execution boundary

Status: implementation decision, owner review pending.

Start with scalar CRUD. Expose no reflected attributes by default. Inputs reject
undeclared, readonly and currently forbidden fields. Omitted update inputs retain
values; false and zero remain values; null is accepted only for nullable fields.
Decimals use exact arithmetic, timestamps use explicit context zones and canonical
UTC digests. No nested attributes enter generic writes in this slice.

Use server-issued, expiring opaque intents. Bind actor, tenant, security version,
resource, operation version, target, expected record version and normalized input.
A deliberate Save binds an initially unbound form intent and consumes human
confirmation in the same transaction as the write. Prepared proposals can bind
input earlier, in which case editing it requires a new proposal. Client-supplied
intent IDs cannot create runs. Cross-origin retries of the same intent dedupe;
independent intents do not dedupe by input digest alone.

Lock intent before domain record. A database unique key owns the intent. The
framework may use a savepoint to roll back a failed operation inside a caller's
transaction; handlers may not use independent pools or external effects. Success,
receipt, confirmation and audit commit together. Replay reauthorizes and projects
current readable data. Validation does not persist a successful run. Receipts
retain only refs/digests, never full record snapshots or raw submitted payloads.

PostgreSQL row locking and SQLite contention need separate concurrency evidence.
A SQLite busy result is a retryable conflict, never an assumed success.

The 2026-10-30 extension adds explicit member handlers and a post-commit outbox,
without changing the common Runner boundary. Native preflight/confirmation binds
custom input before execution; changed target attributes require an advanced
lock_version. Receipt and delivery grants are separate from command eligibility.
See ADR 0006 for leases, request fingerprints, unknown outcomes and recovery.
Collection/global actions, CRUD overrides and asynchronous business execution
remain later requirements; this extension does not close a full phase or Gate.
