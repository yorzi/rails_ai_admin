# Public contract (development)

No stable release contract is frozen. Supported APIs are backed by executable
contract tests and the packaged fixture host. The development plan contains
additional target APIs which are not implemented merely because they are listed.

Use one `RailsAiAdmin::Engine` mount whose final helper name is `rails_ai_admin`,
whose path has no dynamic parameters, and which accepts all HTTP verbs. Static
custom paths and different Rails source spellings are supported. The installer
checks the target application's actual loaded RouteSet, including `draw` files,
`self.mount` and namespace-generated final helper names; it does not parse source
or require literal-only mount syntax. It must run in the application whose root
matches the destination.

Other aliases or helper-name prefixes, dynamic parameters, verb restrictions and
multiple admin mounts are rejected before writing. A non-admin route occupying
`rails_ai_admin` when no admin mount exists is also rejected. Request-local
redaction uses the named mount before Rails logs query parameters; it does not
change the host's global filter list. Host SQL debug logging, custom loggers and
instrumentation remain host responsibilities and can expose domain values.
Use production log levels and never submit credentials as ordinary admin data.

Configure `context_adapter`, `authorization_adapter`, `resources` and `work_handlers` using class
name strings before boot. A context adapter implements `resolve(controller)`.
An authorization adapter implements `scope(context:, resource:, relation:)`,
`allowed?(context:, action:, resource:, record: nil)` and
`fields(context:, resource:, action:, record: nil)`. Default results deny access.
Custom inputs, receipts and delivery have independent default-deny methods:
`operation_fields(context:, resource:, operation:, record: nil)`,
`read_operation_receipt?(context:, resource:, operation:, record:)` and
`deliver_work?(context:, resource:, operation:, work_kind:, record:)`.
Background delivery additionally needs `context_adapter.resolve_job(actor_ref:,
tenant_ref:, security_version:)`, which reconstructs current authority rather than
trusting stored refs/epoch as permission.

Resources declare `model`, `key`, `label`, `title`, optional `policy`, `readonly`, `disable`,
`fields` and explicit member `operation` handlers. Core scalar types are id/text/textarea/integer/decimal/boolean/date/datetime/enum/select.
Registered `Fields::Type` classes refine scalars through `config.field_types`
class-name strings and optional trusted field partials (ADR 0009).
Fields use explicit readonly/required/nullable/create/edit/searchable/sortable
flags. Search/sort grants are independent of read/write. Resources do not scan
model tables at boot. Reserved slugs are rejected by the registry.

Scalar projection and record titles require a model attribute (or the single
primary-key `id` alias) before invoking its getter. Arbitrary model methods cannot
be exposed as scalar fields; a missing attribute fails closed with
`ConfigurationError`. Overrides of real attribute getters remain trusted host
Ruby and must be safe to read; ordinary AR writes are prevented in getters.
`virtual :summary, type:, depends_on:, compute:` provides readonly scalar
computation through a named `Fields::Computation` subclass. Every recursive
read dependency and the virtual field need independent current grants. The
computation gets only frozen declared scalar snapshots, not a model or context.
Graph validation, projection bounds, fresh class/version checks and the usual
scalar/plugin coercion apply. Virtual fields cannot be write/search/sort or
Operation/Work input targets; arbitrary model methods remain inaccessible.
See ADR 0010 and the computed field guide for exact bounds/trust responsibilities.

`Context.new(actor:, tenant:, security_version:, time_zone: "UTC")` requires
stable typed identities. No request/job authority is cached across invocations.
The host is responsible for changing its security version on revocation.

See the operation contract for the native form/preflight/confirmation routes,
registered default CRUD, member handlers and durable post-commit Work. Registered
collection handlers additionally support bounded asynchronous per-target execution.
Global handlers, CRUD replacement, assistant APIs,
exports and associations remain unimplemented. A published dependency API is not
an implemented admin feature.

## Optional Pundit authorization

With host dependency `pundit >= 2.5, < 3`, configure
`authorization_adapter = "RailsAiAdmin::Authorization::PunditAdapter"` and give
each resource an explicit `policy "TicketPolicy"` string. No model-policy
inference or alias fallback occurs. A policy receives the full `Context` and
record/model. Supported predicates are `index?`, `show?`, `create?`, `update?` and
`destroy?`, plus a predicate for each explicitly registered custom operation.
Field grants come separately from `readable_fields`, `writable_fields`,
`searchable_fields` and `sortable_fields`; missing methods return no grants.

The mapped policy or a parent policy class must own its Scope. An unrelated
`Object::Scope` is never inherited. The explicit `Scope.new(context, relation).resolve`
result must obey the complete-filter-relation contract: no limit, offset, select,
group, having or from shapes. Missing policy/scope denies rather than falling back
to an unscoped model; action and field checks remain separate. Normal Pundit action denials return false; unexpected policy failures raise
generic `ConfigurationError` without leaking the original exception text.
Doctor's policy-mapping report checks metadata, not correctness of decisions.

For custom actions, `permitted_operation_fields(operation)` grants typed input
names. `read_operation_receipt?(operation)` authorizes an already committed custom
receipt; replay uses its bound schema only for digest matching and returns generic
`IDEMPOTENCY_CONFLICT` without field errors for changed/invalid input. Current
read/show/scope/epoch still constrain its projection. `deliver_operation_work?(
operation, work_kind)` authorizes a committed fact separately from whether the
original command could be executed again. Missing methods deny.

`Work` handlers use the same scalar input DSL. Payloads are bounded; leases,
independent deadlines and stable request/key evidence are persisted. The host
schedules `rails_ai_admin:work:scan` or `:drain`; optional after-commit enqueue is
an accelerator. Neither an in-memory queue nor a fencing counter proves external
exactly-once delivery. See `docs/reference/operations.md` and ADR 0006 for the full
current contract and reconciliation boundaries.

Host Devise can resolve the context through Warden, a freshly loaded actor and
verified tenant membership. The engine does not add accounts or login routes.
The packaged Devise/PostgreSQL fixture demonstrates this arrangement with UUID
tickets and host-owned product Chat/Surface objects; it does not enable admin AI.

Changing the policy mapping changes the operation fingerprint. Existing
development intents can become invalid; reopen forms and reauthorize them.

## Closed generators and schema suggestions

The conventional install generator supplies a context returning nil, a default-deny
`AdminPolicyAdapter`, an unregistered `ExampleAdmin` and an anonymous HTTP test at
`test/rails_ai_admin/access_test.rb`, alongside migrations and configuration.
These files are scaffolds, not an automatic integration with the host's accounts
or business policies. Existing policy/example/anonymous-test paths are preserved
even with `--force`; initializer and context files still follow normal generator
conflict handling and can be overwritten by that option. Constants conflicting
outside the scaffold paths are rejected before writing. Review real host adapters
instead of treating forced installation as a safe merge. The CLI links to the
actual installed README path rather than an unhosted documentation site.

The resource generator enables only the readonly ID field and does not register
the resource. Supported scalar suggestions, when schema metadata is available,
remain comments. Sensitive/encrypted attributes, foreign keys and polymorphic
foreign-type columns, STI inheritance columns, `lock_version`, authority-like
names such as role/permission/security_version, and unsupported types are excluded
from suggestions. No business rows are sampled.
An unknown model or an unavailable/unmigrated table leaves the safe readonly
scaffold without depending on suggestions. The host must review field meaning,
visibility and policy before registering/enabling it.

## Diagnostic and field-grant helpers

Doctor inspects public adapter methods, the availability/signature of a public
zero-argument `.new`, and obviously incompatible `initialize` or positional/keyword
method signatures, schema metadata, leading-column indexes for
declared sortable fields, sensitive field declarations and the default host
autoload path, alongside its existing mapping, pool and locking diagnostics. Metadata can identify a bad configuration but cannot
prove authentication, authorization, callback safety or confidentiality. Supported
scalar column metadata does not prove every Field/database coercion is compatible.
The `field_types:<resource>` check marks obvious scalar mismatches as `review`,
while clearly incompatible adapter interfaces/signatures are `error` findings.
Neither result proves runtime authentication, formatting or conversion correctness.
It does not sample business records, invoke a provider or automatically repair
indexes.

`TestKit.assert_unauthenticated(adapter:, controller:)` invokes the context
adapter's `resolve(controller)` and requires nil. It checks that direct context
boundary, not an HTTP request; use the generated request test as well.

`TestKit.field_grants(context:, resource:, record: nil, operation: :update)`
returns four string keys, `read`, `write`, `search` and `sort`, each with a sorted
array of field-name strings after the shared DSL/policy intersection. The
operation selects create/update field exposure for the write grant. It does not
apply action permission or record-scope decisions. Pass a representative record
for record-dependent field rules.

`TestKit.assert_field_grants` takes the same arguments plus `expected:` and
compares all four groups exactly after normalizing keys/field names to strings
and sorting. It is not a minimum allowlist. `operation` accepts only `:create` or
`:update`. Keep these checks alongside `assert_access`, `assert_isolated` and
actual request tests. A field snapshot is not an AI exposure
report and does not return/serialize record values or establish that the actor
can access the supplied record. Record-dependent host policies can still inspect
the supplied record when computing their field grants.


## Fixed target selections

`Selections::Builder#capture(context:, resource:, target_ids:)` persists at most
100 distinct canonical IDs and their current `lock_version`. The resource must be
registered and use the same SQLite/PostgreSQL pool as the Selection tables, a single
integer/string/UUID primary key and standard optimistic locking. The separate
`select_records?(context:, resource:)` grant defaults to false. Pundit calls
`select_records?` on the explicitly mapped policy with the resource model class.
Current index/show/SQL scope rules also apply; read/write grants imply no selection
capability. Qualified primary-key subqueries deduplicate authorized joins before
bounding the outer lookup, including models containing PostgreSQL JSON columns.

`#revalidate(context:, selection_ref:, resource: nil, manifest_digest: nil)` returns
a fresh safe snapshot after checking owner, tenant, security epoch, expiry,
resource/model/table/key fingerprint, stored membership digest, current target
versions and permissions. It recomputes permitted bounded labels; persisted rows
contain only identity/version metadata. Invalid manifests are internal
configuration errors, not permission to rebuild targets from a query. UUIDs and
digests identify a stored snapshot; neither is business approval. Revalidation is
a check at read time and does not lock targets for a future action.

Native `POST /:resource/selections` captures checked IDs and redirects with 303 to
`GET /selections/:selection_ref`. These forms work without JavaScript. Selection
expiry or identity/epoch/digest changes give controlled 409 responses; missing or
inaccessible targets remain generic 404. Normal capture/view creates no
OperationRun, business audit or WorkItem. Explicit collection preflight/admission
can then create a parent approval and durable per-target work. Larger 10,000-item
manifests, all-filtered materialization and retention remain roadmap work.
See the Fixed Selections guide for exact snapshot fields and host examples.


## Collection admission and item execution

Register `operation :key, handler: "ClassName", scope: :collection` for a per-target
Operation over one fixed Selection (1–100 targets currently). `Collections::Runner`
provides typed `preflight`, human `admit` and independently authorized `cancel`;
see the operation contract and Collection Operations guide for exact signatures.
Admission returns a queued job ref, not business success. Parent/input/manifest/
operation/owner/deadline bindings are persisted once. Children have no independent
approval and cannot execute through public member routes/Runner entry points.

Worker infrastructure uses `Collections::Dispatcher#run(job_ref, limit: 100)` and
`#scan_pending!(limit: 100, inline: false)`. Host `resolve_job` must reconstruct
current identity and membership. Every item rechecks class and record grants,
versions and owner/generation/lease/deadline; its business/audit/receipt/outbox and
BatchItem completion commit together through the existing Runner. Stale successes
and failure audits cannot finalize another lease. Metadata admission, cancellation,
claim and worker execution refuse an already open external transaction. A handler's
normal joining transaction still belongs to the framework item transaction.

`cancel_operation?(context:, resource:, operation:)` defaults false; Pundit maps
`cancel_operation?(operation)` on the explicit model-class policy. Current parent
receipt authority uses `read_operation_receipt?` with nil/class, while current item
labels/results additionally need scoped show/receipt/field grants. Payloads are
bounded to 4 KiB, stored once and never returned by job views. They are not secret
storage. Aggregate preview is bounded to 256 KiB with a cooperative 30-second budget.
Cancellation retains committed items and their Work; queueing and effects remain
separate statuses. Unknown admission/cancel commit results retain the existing
job ref for recovery; do not create another intent assuming rollback.

Schedule `rails_ai_admin:collections:scan` or bounded `:drain` recovery. Optional
`collection_auto_dispatch = true` accelerates enqueue after commit; it does not
replace persistent host queues and recurring scans. The job UI is an owner/tenant
view, not a complete cross-user administration or reconciliation center. Global
operations, custom CRUD replacement, 10,000-target materialization and retention
remain incomplete.
