# Rails AI Admin

A self-hosted Rails admin engine with explicitly registered resources and one
policy-checked, audited execution boundary for conventional CRUD.

**Unreleased development.** Scalar conventional CRUD is the first implementation
slice. Chat, trusted Surfaces, associations, CSV, private files, batch actions,
metrics dashboards and background operations remain future work. The development
plan describes the target product, not the supported feature set.

The engine supports custom policy adapters and an optional Pundit adapter with
explicit policy mappings per resource. The host owns authentication, tenants,
policies and domain data. Missing context
or policy grants deny access. Generic writes require standard `lock_version`
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

Installation stays closed: the generated `AdminContext` returns nil, the default
policy denies all actions/fields, and a generated resource is readonly with only
its ID declared. Implement host authentication and explicit policies, then review
fields and register class-name strings in the initializer.

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

This declares exposure; it grants no permission. See the runnable host contract
examples in the [configuration guide](docs/site/_getting_started/configuration.md).
Mount with `as: :rails_ai_admin`; the path can be customized. Admin CSS/ESM are
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
