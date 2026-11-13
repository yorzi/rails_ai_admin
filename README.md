# Rails AI Admin

A self-hosted Rails admin engine with explicitly registered resources and one
policy-checked, audited execution boundary for conventional CRUD.

**Unreleased development.** Current code supplies scalar conventional CRUD,
`belongs_to` references with readonly `has_many` panels, registered scalar field
types and partials, synchronous member operations, fixed Selection previews,
bounded asynchronous collection operations, opt-in admin review Surfaces and a
durable outbox for one declared post-commit effect, and an opt-in admin Chat
whose proposals become review Surfaces. Native-provider evidence, streaming and AI
budgets, association search and broader association writes, CSV, private files,
metrics dashboards and the broader batch/job-center workflows remain future work. The
[development plan](docs/development-plan.md) describes the target product, not the
supported feature set.

The engine supports custom policy adapters and an optional Pundit adapter with
explicit policy mappings per resource. The host owns authentication, tenants,
policies and domain data. Missing context or policy grants deny access. Generic writes require a record version
(`lock_version`, or else `updated_at`) and the same Active Record connection pool for domain records,
operation receipts, audit and Work items. Resources with irreversible callback
effects should remain readonly until their host boundary is redesigned and tested.

See [Field Types](docs/site/_core_features/field-types.md) for custom normalization,
validation, fixed Select labels and authorized form/index/show partials. Plugins
refine a core scalar; they do not grant access. [Computed Fields](docs/site/_core_features/computed-fields.md)
derive readonly values from declared, currently readable scalar dependencies.
Neither API exposes arbitrary model methods.

Use [Template Overrides](docs/site/_advanced/template-overrides.md) to copy one
public presentation template and review source/context drift with doctor. Host
overrides remain trusted Rails code and must preserve the execution boundary.

Build ordinary host-owned Rails pages with the public
[Custom Controller and Status API](docs/site/_advanced/custom-controllers.md).
Scoped Access and the shared Runner preserve the execution boundary; host routes,
layouts and partials remain ordinary Rails. The native-session packaged consumer
includes an Order review workbench that shares its operation with native pages.

Link records with [Associations](docs/site/_core_features/associations.md):
references and child lists resolve through each target resource's own grants,
so an association never shows or attaches a record its policy hides.

Group, label, order or hide sidebar and Overview entries with
[Resource Navigation](docs/site/_core_features/resource-navigation.md). The menu
follows current index grants; hiding an entry changes no direct authorization.

## Develop

To see the admin before installing it anywhere, run the demo. It copies the
packaged session/SQLite host to `tmp/demo`, seeds sample data and serves it on
127.0.0.1 only; Ctrl-C stops it:

```sh
bin/demo               # http://127.0.0.1:3917/staff, admin@example.test / demo-password
bin/demo --assistant   # also admin Chat, against an offline fake provider (no key)
```

```sh
bundle install
bundle exec rake test
bundle exec rake build
```

The build creates `pkg/rails_ai_admin-<version>.gem` (currently `0.1.0.dev`); it
does not publish. `bundle exec rake release:check` reports release readiness, and
[RELEASING.md](RELEASING.md) lists the next release's open gates and procedure. The
[ten-minute quickstart](docs/site/_getting_started/quickstart.md) goes from an app
with Rails 8 sign-in to a working, policy-checked Users admin. The
[installation guide](docs/site/_getting_started/getting-started.md) covers other
hosts and adding a local build or development checkout. Then run:

```sh
bin/rails generate rails_ai_admin:install
bin/rails db:migrate
bin/rails generate rails_ai_admin:resource Customer
bin/rails rails_ai_admin:doctor
```

Installation stays closed: the generated `AdminContext` returns nil and the
`AdminPolicyAdapter` stub denies all actions/fields. The install generator also
provides an unregistered `ExampleAdmin` and an anonymous HTTP test at
`test/rails_ai_admin/access_test.rb`. These are starting points, not a working
authentication integration.

The resource generator keeps only a readonly ID enabled and leaves the resource
unregistered. When model schema is available, it adds commented scalar field
suggestions for review. It does not sample records; sensitive/encrypted fields,
foreign keys and polymorphic type columns, STI inheritance columns,
`lock_version`, authority-like names such as role/permission/security_version,
and unsupported types are excluded from suggestions. A declared non-polymorphic
`belongs_to` is suggested as a commented `belongs_to` field.
Missing models or unavailable table metadata still leave the safe readonly scaffold.
Implement host authentication and explicit policies, then review fields and
register class-name strings in the initializer.

```ruby
RailsAiAdmin.configure do |config|
  config.context_adapter = "AdminContext"
  config.authorization_adapter = "AdminPolicyAdapter"
  config.resources = ["CustomerAdmin"]
end
```

```ruby
class CustomerAdmin < RailsAiAdmin::Resource
  model "Customer"
  key :customers
  title :name

  fields do
    id :id
    text :name, required: true, nullable: false,
      searchable: :prefix, sortable: true
  end
end
```

Run the generated anonymous request test before and after adapting the host:

```sh
bin/rails test test/rails_ai_admin/access_test.rb
```

Doctor reports obviously incompatible public zero-argument constructors/signatures, schema,
field-type review hints, sortable-index and sensitive-declaration findings,
and default autoload-path diagnostics. Its metadata cannot prove authentication
or authorization. `TestKit` provides separate anonymous-context, action, tenant
and exact field-grant assertions; field-grant snapshots are not an AI exposure
report. See the [host verification guide](docs/site/_advanced/host-verification.md).

Resources can also declare named index tabs with `scopes`. Each tab needs its own
default-deny `named_scopes` grant and can only narrow the policy relation; see
the [Named Scopes guide](docs/site/_core_features/named-scopes.md). Fields can opt
into typed exact/range filters with `filterable:`, behind a separate default-deny
`:filter` field grant; see the [Typed Filters guide](docs/site/_core_features/typed-filters.md).
An `index` block chooses columns, a default sort, page size and an optional
bounded count; see the [Index Tables guide](docs/site/_core_features/index-tables.md).

The resource declaration grants no permission. See the runnable host contract
examples in the [configuration guide](docs/site/_getting_started/configuration.md).
Use one static-path engine mount whose final helper name is `rails_ai_admin`,
with no HTTP-verb restriction. Run installation inside the target Rails app; its
loaded routes are checked before writing, including drawn files and namespace
prefixes. Other helper names, dynamic path parameters and multiple mounts are
rejected. Admin CSS/ESM are
prebuilt in the gem, so a host does not need Node to compile them. No provider key,
AI table or provider call is required for conventional mode.

## Custom Operations and Follow-Up Delivery

Register a `RailsAiAdmin::Operation` on a resource for a synchronous member command.
Its native input form leads to input-bound preflight and a separate human
confirmation, using the same Runner/receipt/audit transaction as CRUD. Operation
inputs, committed-receipt reads and follow-up delivery have independent grants;
ordinary editable-field permissions do not grant them. Successful custom receipt
replay compares its already bound schema/input digest, not current input grants;
failed or changed replay input returns a generic conflict without field errors.
See the
[Operation guide](docs/site/_core_features/operations.md).

`RailsAiAdmin::Work` reuses the input DSL for post-commit delivery. Registered
`config.work_handlers` persist bounded payload/digest intent through
`context.outbox.enqueue`. Work performs one declared `context.effect(request:)`
using a stable downstream delivery key and a dedicated digest of its plain JSON
wire request. Typed values must be serialized first; normalized key collisions,
nonfinite floats and unsupported objects are rejected. Ordinary Active Record
writes in Work/effect execution are guarded, while trusted Ruby remains outside
a sandbox. A successful business result does not
mean the effect finished. Outbox auto-dispatch defaults to false; the host must
schedule `rails_ai_admin:work:scan` or bounded `work:drain` recovery. Optional
after-commit enqueue is only an accelerator.

The default exact record-version policy stops delivery after later record edits.
Unknown non-idempotent effects require reconciliation rather than automatic
retry. Leases/fencing and persistent payloads do not establish downstream
exactly-once execution. Read the [Durable Outbox guide](docs/site/_advanced/durable-outbox.md)
before enabling a real transport. Preflight's Active Record write guard is not a
trusted-Ruby sandbox, and operation duration checks do not hard-interrupt Ruby/SQL.
Global operations, CRUD handler replacement and AI/Surface dispatch remain
unavailable; complete release Gates remain open.

## Review Surfaces

Hosts that already use rails_tool_views can set `config.surfaces = true` and mark
member operations `surface: true`. A native review can then be saved as a
persistent Surface that confirms the same intent once, through admin-owned
endpoints that leave the host's rails_tool_views settings untouched. Operations
marked `assistant: true` can also be proposed by an assistant through the
on-demand `raa_propose_operation` RubyLLM tool; only the user's Surface
confirmation executes them. See the
[Review Surfaces guide](docs/site/_advanced/review-surfaces.md).

## Admin Assistant

Hosts that load ruby_llm can run `bin/rails generate rails_ai_admin:assistant`
and set `config.assistant = true`. The assistant reads records through each
admin's current grants plus a default-deny `assistant?` grant. It cannot change
data: a suggested change opens the same review Surface, and only the person's
confirmation writes it, once. Turns run in jobs through a leased inbox that
recovers after crashes without repeating messages. Provider settings come from
your own adapter, never from global RubyLLM configuration. See the
[Admin Assistant guide](docs/site/_advanced/admin-assistant.md).

## Fixed Selection Previews

A default-deny `view_history?` grant adds a record History page listing its audited
changes (fields named only when currently readable or writable).

A separate default-deny `select_records?` grant enables native index checkboxes
and a no-JavaScript preview of up to 100 explicit targets. `Selections::Builder`
captures exact canonical IDs/versions and revalidates ownership, security version,
expiry, resource contract and current record/field grants. Newly matching records
or same-count replacements cannot expand a captured manifest. Labels are freshly
projected; only IDs/versions/positions and parent binding metadata are persisted.

Capture is not operation approval and creates no OperationRun, business audit,
Work item or job. See [Fixed Selections](docs/site/_core_features/selections.md).

## Asynchronous Collection Operations

Register an `Operation` with `scope: :collection` to apply its per-record handler
to a fixed Selection of at most 100 targets. Native input, pure review and explicit
**Confirm and queue** create one approved parent with durable child intents/items;
admission performs no domain mutation. Each worker attempt rebuilds current host
authority and commits a target change, audit, receipt, optional outbox and item
completion in one transaction. Public member execution cannot execute child intents.

Items commit independently. Cancellation stops remaining uncommitted items and
preserves committed changes and their Work. Approval expiry controls admission;
a separate execution deadline bounds the admitted run. Job receipts use separate
current receipt grants; cancellation needs its own `cancel_operation?` grant.
The parent stores bounded typed input once, so exclude credentials and secrets.

`collection_auto_dispatch` defaults to false. The host supplies `resolve_job`, a
persistent queue and recurring `rails_ai_admin:collections:scan` (or bounded
`collections:drain`); after-commit enqueue only accelerates recovery. Read
[Collection Operations](docs/site/_core_features/collection-operations.md) before
enabling workers. All-filtered/10,000-target manifests, global operations, a full
job center and retention remain planned; this bounded slice does not close the
full roadmap or release Gates.

## Read the Contracts

- [Architecture](ARCHITECTURE.md), [public contract](docs/reference/public-contract.md)
  and [operation semantics](docs/reference/operations.md).
- [Resources and fields](docs/site/_core_features/resources-and-fields.md),
  [host verification](docs/site/_advanced/host-verification.md) and
  [data/security boundaries](docs/site/_advanced/data-and-security.md).
- [Compatibility evidence](COMPATIBILITY.md), [roadmap](ROADMAP.md) and
  [dependency integration constraints](docs/reference/dependency-contracts.md).

An independent [Devise/Pundit/PostgreSQL consumer](spec_hosts/devise_postgres)
exercises UUID tickets, verified tenant memberships, development reload and
fresh-process crash/replay using the built gem. Its Propshaft/jsbundling and
Sprockets/jsbundling modes are asset variants of one consumer. See the
[Pundit/Devise guide](docs/site/_advanced/pundit-and-devise.md) and
[host verification guide](docs/site/_advanced/host-verification.md). The engine
does not provide accounts or login routes. The fixture's separate product Chat
and Surface remain host-owned, beside its opt-in admin Chat.

Changing a resource's policy mapping changes its operation fingerprint. Reopen
existing development forms if their old intents are invalidated.

The Jekyll/RDoc site lives under `docs/site/`. It is a local documentation source;
no hosted site or remote repository is implied. Build it with
`docs/site/bin/build.sh` after installing its separate bundle.

Local automated checks and internal review do not establish production readiness,
independent security review, real-provider behavior or user acceptance. Release
gates remain in the plan; publishing requires explicit maintainer approval.

Licensed under [MIT](LICENSE). Dependencies retain their own licenses in
[third-party notices](THIRD_PARTY_NOTICES.md). Read [SECURITY.md](SECURITY.md) before
reporting a vulnerability and [CONTRIBUTING.md](CONTRIBUTING.md) before contributing.
