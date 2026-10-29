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

Resources declare `model`, `key`, `label`, `title`, `readonly`, `disable` and
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
