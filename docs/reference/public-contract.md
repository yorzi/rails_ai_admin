# Public contract (development)

No stable release contract is frozen. Supported APIs are backed by executable
contract tests and the packaged fixture host. The development plan contains
additional target APIs which are not implemented merely because they are listed.

Mount with `as: :rails_ai_admin`. The path itself is configurable. Request-local
redaction uses that named mount before Rails logs query parameters; it does not
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
