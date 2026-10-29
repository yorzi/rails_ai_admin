# ADR 0007: Fixed target manifests before collection admission

Status: implementation decision; owner review and full release gates remain open.

## Decision

Capture an explicit interactive selection as immutable namespaced Selection and
SelectionItem rows. The current bound is 100 distinct canonical target IDs, each
with a nonnegative `lock_version`, in one SQLite/PostgreSQL connection pool.
Selection stores owner, tenant, security epoch, registered resource and stable
model/table/primary-key contract, count, ordered membership digest and expiry.
Items store only target ID, expected version and position. Labels, field values
and source queries are not retained. Capture/view does not create OperationRun,
approval, audit or post-commit Work.

An independent default-deny `select_records?(context:, resource:)` grants capture
and viewing; index/show, SQL scope and readable title fields still apply. Pundit
uses the explicit mapped policy with the resource model class. Native checkbox
capture and redirect-to-preview operate without JavaScript. Every preview checks
fresh owner/tenant/epoch, expiry, resource identity, stored integrity, current
permissions and target versions. A valid record whose title is unreadable uses a
bounded generic label. Missing or foreign targets reject the whole selection.

The scope may contain joins that duplicate records. The framework builds a
DISTINCT primary-key subquery from the complete authorized relation, removing
only ordering, then reconstitutes exactly those IDs in one bounded outer query.
The outer query has no default scope of its own and cannot select an ID outside
that authorized subquery. This avoids truncation before deduplication and avoids
PostgreSQL DISTINCT equality requirements on unrelated JSON columns. No saved
query is expanded during revalidation.

The manifest digest detects accidental/internal membership corruption; it is not
a secret capability or a substitute for current authorization. Model getters and
policies remain trusted host Ruby. Normal AR writes during selection lookup are
prevented, without claiming a general Ruby/network/filesystem sandbox.

## Consequences and execution handoff

Changing physical table or primary-key semantics changes identity fingerprints.
Existing operation intents and selection snapshots are invalidated before loading
an old target under the new meaning. Fingerprints contain stable schema metadata,
not process-local connection IDs. Ordinary permission changes still depend on
fresh policies and the host's security epoch discipline.

Capture/view provides a usable prerequisite for the full collection workflow.
Collection execution remains unimplemented. Its parent OperationRun must consume
one approval atomically with durable admission, binding this exact manifest digest,
operation version and normalized inputs. Each admitted item needs a unique receipt,
fresh permission/version/deadline checks and transactional owner/generation fences
through the shared Runner. Workers must not create another human approval or let
HTTP execute child intents independently. Cancellation preserves committed items
and stops remaining items; partial success cannot be described as batch rollback.

The eventual 10,000-target asynchronous capture, approval/admission, item workers,
retries, job/result views and retention/cleanup remain required in the full plan.
Expiry currently rejects use and does not delete rows. No release gate is closed.
