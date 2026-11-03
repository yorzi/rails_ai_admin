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
`fields`, `index` table settings, named list `scopes` and explicit member `operation` handlers. Core scalar types are id/text/textarea/integer/decimal/boolean/date/datetime/enum/select.
Registered `Fields::Type` classes refine scalars through `config.field_types`
class-name strings and optional trusted field partials (ADR 0009).
Fields use explicit readonly/required/nullable/create/edit/searchable/sortable/filterable
flags. Search/sort/filter grants are independent of read/write. Resources do not scan
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
Global handlers, CRUD replacement, assistant APIs (beyond the opt-in review
Surface below), exports and associations remain unimplemented. A published dependency API is not
an implemented admin feature.

## Optional Pundit authorization

With host dependency `pundit >= 2.5, < 3`, configure
`authorization_adapter = "RailsAiAdmin::Authorization::PunditAdapter"` and give
each resource an explicit `policy "TicketPolicy"` string. No model-policy
inference or alias fallback occurs. A policy receives the full `Context` and
record/model. Supported predicates are `index?`, `show?`, `create?`, `update?` and
`destroy?`, plus a predicate for each explicitly registered custom operation.
Field grants come separately from `readable_fields`, `writable_fields`,
`searchable_fields`, `sortable_fields` and `filterable_fields`; missing methods
return no grants.

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
from suggestions; a declared non-polymorphic, non-sensitive belongs_to is suggested
as a commented `belongs_to` field unless its name is tenant-like (account, tenant,
organization, workspace, company, team). No business rows are sampled.
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
returns five string keys, `read`, `write`, `search`, `sort` and `filter`, each with a sorted
array of field-name strings after the shared DSL/policy intersection. The
operation selects create/update field exposure for the write grant. It does not
apply action permission or record-scope decisions. Pass a representative record
for record-dependent field rules.

`TestKit.assert_field_grants` takes the same arguments plus `expected:` and
compares all five groups exactly after normalizing keys/field names to strings
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

## Conventional template overrides

`bin/rails generate rails_ai_admin:override --list` describes the current public
paths and explicit context. Generate one key, keep its first-line source/version/
context header and review the trusted host body. Existing files are never replaced,
even with `--force`; revoke preserves them too. Doctor compares source SHA and
context revision without evaluating ERB; `CURRENT` is metadata agreement, not
host-body safety or a compatibility certificate. Stale/manual/incomplete findings
need review. Only standard `app/views/rails_ai_admin` and
`app/views/layouts/rails_ai_admin` namespaces are inspected.

New/edit wrappers apply to GET, validation and conflict and keep the existing
shared full form. Global field display/input defaults are overrideable; explicit
field-type partials win. Scope/field/action decisions, CSRF, intent/confirmation,
escaping, dirty-form and flow IDs remain part of the review. Fixed HTML statuses
add status_layout/status_page; the resource_navigation partial, field_reference
and resource_associations bring the catalog to 29 entries. Non-HTML plain responses and future Surface wrappers remain outside
it. See ADR 0011/0015/0016 and the site template guide/catalog for exact paths and
bounds.

## Associations

`belongs_to :name, resource: :key, foreign_key: "name_id", filterable: true`
declares a reference field named after the association that reads and writes its
foreign-key column. `Field#column` is that column (the field name for every other
type). Values are the target primary key as bounded text
(`[A-Za-z0-9][A-Za-z0-9_-]{0,99}`), never records. Targets must be registered at
boot; first use and doctor require a matching non-polymorphic model reflection
to the target's single primary key. Search and sort are rejected; filters offer
`eq` behind the independent `:filter` grant. Field types cannot refine
`belongs_to`.

Labels, links and picker options come only from the target resource's current
relation, show grant and title read grant through `Fields::Association`, a
request-local resolver that loads a column's references in one bounded query.
Missing, foreign and hidden targets are indistinguishable (`Customer #42`,
unlinked). Pickers list at most 100 targets the actor may index; otherwise forms
accept a typed key. The Runner rejects a changed reference that is not currently
visible (`is not an available choice`) in the write transaction, accepts an
unchanged stored one, and maps a foreign-key violation to CONFLICT with full
rollback. Audit `changed_fields` and validation errors use field names.

`has_many :name, resource: :key, via: :field, label:, limit:` adds a readonly
show-page panel of at most 50 children read through the child resource's index
grant, policy relation and a read grant on its reference field, with an optional
filtered "View all" link while that field is filter-granted. At most 10 panels
per resource; they add no write path. See ADR 0021.

## Resource menus

`Resource.navigation(group:, label:, icon:, order:, hidden:)` and
`navigation false` declare immutable, cosmetic `Navigation::Settings`. Text is
bounded plain UTF-8, order is -1000..1000, hidden is Boolean and icons come from a
fixed name set. Registration rejects an unusable fallback label for a visible
entry. `Navigation::Menu.build` authorizes index before reading metadata and
returns frozen groups/entries without records, counts or stored grants. The
request-memoized `resource_navigation` helper feeds the layout and dashboard;
`visible_resources` keeps returning every index-authorized resource. Menu
settings change no direct authorization and are excluded from operation-intent
and Selection identity. See ADR 0016 and the Resource Navigation guide.


## Named list scopes

`Resource.scopes { scope name, body = nil, label: nil, default: false }` declares
at most 20 lowercase-named tabs with bounded plain labels, an optional single
default and zero-argument lambda bodies (nil means the whole authorized relation).
Bodies are evaluated only when used, under write prevention, and must return the
resource model's relation without limit/offset/select/group/having/from/eager
loading. The result is intersected as `policy.where(pk => body.select(pk))`, so it
can only narrow; composite primary keys are rejected. Failures are generic
`ConfigurationError`s.

The adapter's `named_scopes(context:, resource:)` grant (Pundit:
`permitted_named_scopes`) is default-deny and independent of index/read/search/
sort, because a predicate can reveal unreadable fields. `Access#named_scopes`
returns declared scopes intersected with it. `Queries::List#call(scope:)` applies
the granted default for nil and otherwise requires a declared, granted name
(INVALID_QUERY); `Page#scope` reports the applied name. List hints add a `scope`
key, drop the granted default and discard revoked scopes; strict index requests
reject undeclared names with 422. TestKit offers `named_scope_grants` and
`assert_named_scopes`. See ADR 0017 and the Named Scopes guide.

## Typed list filters

`filterable: true` selects `eq` for id/text/textarea/enum/select/boolean and
inclusive `gte`/`lte` for integer/decimal/date/datetime; an Array narrows to
allowed operators (range types also allow `eq`). Virtual/hidden fields cannot
filter, and undeclared fields keep unchanged contracts. The adapter's
`fields(action: :filter)` grant (Pundit `filterable_fields`) is default-deny and
independent of read/search/sort. `Queries::List#call(filters:)` ANDs at most 20
`{ field => { operator => String } }` conditions, coerces each value through the
field contract (Context time zone for datetimes) and binds it with Arel; anything
undeclared, ungranted or out of contract is INVALID_QUERY. List hints carry a
canonical nested `filter`, strict index requests reject invalid filters with 422,
revoked grants are discarded and blank form submissions redirect once to the
canonical URL. Decoded recovery-header JSON may use 1,536 bytes. See ADR 0018 and
the Typed Filters guide.

## Index table settings

`Resource.index { columns; default_sort name, direction; page_size; count }`
declares static presentation checked against fields at registration: 1..50
index-visible columns, a sortable non-virtual default sort, a 1..100 page size
(default 25) and `count :none` (default) or `:exact`. Columns only order/narrow
current read grants, masks and dependency rules; the projection computes listed
columns plus the title. The default sort applies only while its sort grant holds
and is implicit in hints. Exact counts cover the authorized filtered relation and
stop at 10,000 (`Page#count_capped`). `Page` also reports `sort`, `direction` and
`page_size`. Settings are excluded from operation/Selection identity. See ADR 0019
and the Index Tables guide.

## Admin review Surfaces (opt-in)

`config.surfaces = true` requires the host to load rails_tool_views and its tables;
otherwise boot fails. Member operations opt in with `operation ..., surface: true`.
Admin-owned routes (`POST :resource/:id/operations/:operation/surface`,
`GET assistant/surfaces/:id`, `POST assistant/surfaces/:id/actions`) call the
public rails_tool_views API with an explicit `raa:` Scope; the host's resolver,
parent controller, adapter, auto_deliver and registry are never read or changed.
The `raa_operation_review` component stores only the intent UUID and canonical
input, re-registers after host resets and rejects squatting. Its policy/handler
require the matching request-bound admin Context. Presentation requires an
unconsumed native intent with matching input digest; confirmation runs the shared
Runner on the same intent (`origin: surface`) inside the Surface lock, writing
once across channels. Completed reviews need the receipt grant. No assistant
presentation is available through the opt-in assistant below; in-Surface editing
and Surface template overrides do not exist. See ADR 0020 and the Review Surfaces
guide.

## Admin assistant (opt-in)

`config.assistant = true` requires the host to load ruby_llm and names
`assistant_adapter` (a class whose `llm_context(context:)` returns a
`RubyLLM::Context` or nil), `assistant_model`, and optionally
`assistant_provider`/`assistant_protocol`. The admin never reads or changes
global RubyLLM settings; conventional hosts load no RubyLLM code. The
`rails_ai_admin:assistant` generator adds Engine-owned chat, message and turn
tables (and RubyLLM's shared model, tool-call and usage tables only when absent)
plus a closed adapter. Routes under `assistant` (`GET assistant`,
`POST assistant/conversations`, `GET|POST assistant/conversations/:chat_ref`
with `messages`, `cancel`, `retry` and `archive`) exist only when enabled.

The default-deny adapter grant `assistant?(context:, resource:)` (Pundit:
`assistant?`) exposes a resource to the model; the pages exist when any resource
grants it. Tools (`list_resources`, `describe_resource`, `search_records`,
`get_record`, and `propose_operation` with Surfaces) apply current index, show,
read, search, filter and operation grants and return bounded JSON with fixed
error codes. A chat is bound to actor, tenant and security version.

A request only admits a turn keyed per chat; workers claim the lowest active
turn under a lease and fencing generation, rebuild authority with
`resolve_job`, persist the human message once and drive RubyLLM outside
transactions. `propose_operation` prepares an `origin: assistant` intent and
presents `raa_operation_review`; the human's Surface confirmation commits the
business write and admits one `intent:` continuation turn in the same
transaction. `rails_ai_admin:assistant:scan`/`drain` recover queued or expired
turns. Usage rows are owned by the admin chat. No streaming, budgets, page
context, live-provider evidence or retention exist yet. See ADR 0022 and the
Admin Assistant guide.

## Host controllers and fixed statuses

`RailsAiAdmin::CustomController` inherits fresh admin authentication, CSRF,
private responses/security headers and action-parameter filtering. It selects
`layout false` and retains host route/view lookup. Protected entry points are
admin_context, admin_access(registered_key), admin_operation_runner, admin_routes,
admin_csp_nonce and admin_status(kind). admin_routes/admin_csp_nonce are also view
helpers. Resolving Access grants nothing; use current scoped lookup and field
projection. Writes use the shared Runner with explicit command/target binding.

Use the mounted admin_routes proxy for Engine links, including SCRIPT_NAME;
unqualified helpers remain the host's. Optional engine-prefix host routes are
registered with Engine.routes.prepend in an initializer before drawing. Initial
Started-URL redaction outside the Engine mount remains the host's responsibility.
Host layouts loading the prebuilt bundle need csp-nonce meta from admin_csp_nonce.

`Presentation::Status.fetch` accepts only authentication_required (401), forbidden
(403), not_found (404), conflict (409), invalid_query/invalid_request (422),
unavailable (503) and error (500). Explicit forbidden is for a host page decision;
normal hidden/unknown records and unknown access codes still produce matching
anti-enumeration 404. Exception/request/business text and return URLs are not
inputs. `return admin_status(kind)` is required to halt subsequent action work.
HTML/Turbo uses minimal fixed HTML with reload metadata and no resource navigation;
non-HTML stays plain text. A failing status override falls back to fixed plain
text with the same HTTP status/session marker, never a false recovery-ready marker.
Unhandled action exceptions remain the host's error-handling responsibility.

See ADR 0015 and the custom-controller guide for the packaged Order example,
ordinary HTML preview/303 confirmation contract and extension trust boundary.
