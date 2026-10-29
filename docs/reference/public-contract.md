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

Configure `context_adapter`, `authorization_adapter` and `resources` using class
name strings before boot. A context adapter implements `resolve(controller)`.
An authorization adapter implements `scope(context:, resource:, relation:)`,
`allowed?(context:, action:, resource:, record: nil)` and
`fields(context:, resource:, action:, record: nil)`. Default results deny access.

Resources declare `model`, `key`, `label`, `title`, optional `policy`, `readonly`, `disable` and
`fields`. Field types are id/text/textarea/integer/decimal/boolean/date/datetime/enum.
Fields use explicit readonly/required/nullable/create/edit/searchable/sortable
flags. Search/sort grants are independent of read/write. Resources do not scan
model tables at boot. Reserved slugs are rejected by the registry.

`Context.new(actor:, tenant:, security_version:, time_zone: "UTC")` requires
stable typed identities. No request/job authority is cached across invocations.
The host is responsible for changing its security version on revocation.

See the operation and HTTP contracts added alongside the vertical slice. Custom
handlers, assistant APIs, exports, associations and async execution are not yet
publicly supported. A published dependency API is not an implemented admin feature.

## Optional Pundit authorization

With host dependency `pundit >= 2.5, < 3`, configure
`authorization_adapter = "RailsAiAdmin::Authorization::PunditAdapter"` and give
each resource an explicit `policy "TicketPolicy"` string. No model-policy
inference or alias fallback occurs. A policy receives the full `Context` and
record/model. Supported predicates are `index?`, `show?`, `create?`, `update?` and
`destroy?`. Field grants come separately from `readable_fields`, `writable_fields`,
`searchable_fields` and `sortable_fields`; missing methods return no grants.

The mapped policy or a parent policy class must own its Scope. An unrelated
`Object::Scope` is never inherited. The explicit `Scope.new(context, relation).resolve`
result must obey the complete-filter-relation contract: no limit, offset, select,
group, having or from shapes. Missing policy/scope denies rather than falling back
to an unscoped model; action and field checks remain separate. Normal Pundit action denials return false; unexpected policy failures raise
generic `ConfigurationError` without leaking the original exception text.
Doctor's policy-mapping report checks metadata, not correctness of decisions.

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
