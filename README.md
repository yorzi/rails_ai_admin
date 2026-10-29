# Rails AI Admin

A self-hosted Rails admin engine with explicitly registered resources and one
policy-checked, audited execution boundary for conventional CRUD.

**Unreleased development.** Scalar conventional CRUD is the first implementation
slice. Chat, trusted Surfaces, associations, CSV, private files, batch actions,
metrics dashboards and background operations remain future work. The development
plan describes the target product, not the supported feature set.

The engine supports custom policy adapters and an optional Pundit adapter with
explicit policy mappings per resource. The host owns authentication, tenants,
policies and domain data. Missing context or policy grants deny access. Generic writes require standard `lock_version`
optimistic locking and the same Active Record connection pool for domain records,
operation receipts and audit. Resources with irreversible callback effects should
remain readonly.

## Develop

```sh
bundle install
bundle exec rake test
bundle exec rake build
```

The build creates `pkg/rails_ai_admin-0.1.0.dev.gem`; it does not publish. Use the
[installation guide](docs/site/_getting_started/getting-started.md) to add a local
build or development checkout to a host. Then run:

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
and unsupported types are excluded from suggestions.
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

The resource declaration grants no permission. See the runnable host contract
examples in the [configuration guide](docs/site/_getting_started/configuration.md).
Use one static-path engine mount whose final helper name is `rails_ai_admin`,
with no HTTP-verb restriction. Run installation inside the target Rails app; its
loaded routes are checked before writing, including drawn files and namespace
prefixes. Other helper names, dynamic path parameters and multiple mounts are
rejected. Admin CSS/ESM are
prebuilt in the gem, so a host does not need Node to compile them. No provider key,
AI table or provider call is required for conventional mode.

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
and Surface remain host-owned; admin Chat/continuation is not yet implemented.

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
