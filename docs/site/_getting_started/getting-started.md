---
layout: default
title: Getting Started
nav_order: 1
description: Install the development gem and connect a closed admin engine to your host.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* How to install a local development build.
* How to mount the engine and register a resource.
* Which host contracts you must implement before enabling access.

## Install a Development Build

This project has no published gem release. From this checkout, build the package:

```sh
bundle install
bundle exec rake test
bundle exec rake build
```

Install the resulting `pkg/rails_ai_admin-{{ site.version }}.gem` into a development
host's bundle. During source development, a sibling checkout is also usable:

```ruby
# Host Gemfile, development only
gem "rails_ai_admin", path: "../rails_ai_admin"
```

The runtime requires Ruby 3.3 or newer and Rails 8.0.5.2 to below 8.2; on Rails 8.1
use 8.1.4.1 or newer (doctor reports an older patch release). CI runs the
engine suite on Ruby 3.3 and 4.0 with Rails 8.0 and 8.1; the range does not prove
every combination has passed, so consult `COMPATIBILITY.md` in the checkout for
executed evidence. On Rails 8.0 keep `json` below 3: Active Support 8.0's encoder
fails on json 3. Generic writes target SQLite and PostgreSQL.

## Install the Closed Engine

In the host:

```sh
bundle install
bin/rails generate rails_ai_admin:install
bin/rails db:migrate
bin/rails generate rails_ai_admin:resource Customer
bin/rails rails_ai_admin:doctor
```

The install generator copies conventional execution/audit migrations, a
configuration initializer, a closed `AdminContext`, a default-deny
`AdminPolicyAdapter`, an unregistered `ExampleAdmin`, and an anonymous request test
at `test/rails_ai_admin/access_test.rb`. It adds the `/admin` mount named
`rails_ai_admin` when the host has no existing admin engine mount. The generated
context returns `nil`; the generated policy grants no actions or fields. An
authenticated host user receives no automatic permission.

The generator does not create users, roles, provider settings or assistant tables.
It preserves an existing policy scaffold, example declaration or anonymous test,
even with `--force`. The initializer and `AdminContext` still use normal generator
conflict handling: `--force` can overwrite those files. Review them before rerunning
installation; do not treat the force option as a safe merge of real authentication.
Conflicting scaffold constants loaded from other paths are rejected before writing.
Run installation inside the target Rails application: its actual loaded RouteSet
is checked before writing. The destination must match that application's root;
pointing the generator at another directory is refused. The check handles drawn
route files and the final names produced by namespace/self.mount syntax, rather
than parsing a particular Ruby source spelling.

Only one admin engine mount is supported, with final helper name `rails_ai_admin`,
a path without dynamic parameters, and all HTTP verbs. A static custom path is
retained. Other aliases, namespace-generated helper prefixes, dynamic parameters,
verb restrictions or multiple admin mounts are rejected before files are written.
If no admin mount exists but another route already owns the `rails_ai_admin` name,
installation refuses the collision rather than adding a conflicting route.

The setup message links this guide in the source repository; the gem ships no
`docs/` directory. `ExampleAdmin` is an unregistered declaration to
review, not a discovered business model or live endpoint. The generated test checks
the anonymous HTTP boundary; run it before and after adapting authentication:

```sh
bin/rails test test/rails_ai_admin/access_test.rb
```

A passing anonymous test does not prove a logged-in policy or tenant boundary.

## Connect Host Authority

Implement your host's [context and policy adapters]({% link _getting_started/configuration.md %}).
Then register the reviewed resource in the initializer:

```ruby
RailsAiAdmin.configure do |config|
  config.context_adapter = "AdminContext"
  config.authorization_adapter = "AdminPolicyAdapter"
  config.resources = ["CustomerAdmin"]
end
```

Use class name strings. Initializers run once, while Rails can reload host classes.
Configuration freezes after initialization; the registry rebuilds in `to_prepare`.

## Review Suggested Fields

`rails_ai_admin:resource Customer` emits a readonly resource with only its ID
enabled, and does not register it. If schema metadata is available, supported
scalar columns appear as commented suggestions. Sensitive names, encrypted
attributes, foreign keys and polymorphic foreign-type columns, the STI inheritance
column, `lock_version`, authority-like names such as `role`, `permission` and
`security_version`, and unsupported column types are excluded. A declared
non-polymorphic `belongs_to` becomes a commented `belongs_to` suggestion instead
of a raw key column; see [Associations]({% link _core_features/associations.md %}).
The generator reads schema metadata, not sample records or business values.

To enable some suggestions straight away, name them with `--fields`; each may
carry its type as a check:

```sh
bin/rails generate rails_ai_admin:resource Customer --fields name:text points active
```

Each named field must be one the schema already suggests, so a sensitive,
foreign-key, tenant or internal column is refused rather than enabled, and a type
that differs from the suggestion is an error. Named fields are written active, the
first text field becomes the title, and the resource stays `readonly`; the other
suggestions stay commented. Your policy must still grant the fields.

An unknown model or an unavailable/unmigrated table does not cause automatic
exposure: the generator leaves the safe readonly declaration without relying on
suggestions. Review field meaning and host policy yourself; a harmless column name
is not proof that its contents are nonsensitive.

After reviewing the model and policy, replace the generated declaration and
register it deliberately:

```ruby
# app/rails_ai_admin/customer_admin.rb
class CustomerAdmin < RailsAiAdmin::Resource
  model "Customer"
  key :customers
  label "Customers"
  title :name

  fields do
    id :id
    text :name, required: true, nullable: false,
      searchable: :prefix, sortable: true
    integer :points
    boolean :active
  end
end
```

This example expects `Customer` columns `account_id`, `name`, `points`, `active`
and `lock_version`. Your policy supplies tenant scoping. For an existing table,
add optimistic locking with a reviewed migration before enabling generic writes:

```ruby
add_column :customers, :lock_version, :integer, null: false, default: 0
```

Keep the resource `readonly` if callbacks send mail, call remote services or cause
other effects that cannot roll back with the database. Run doctor and host tests
before using even the development build with administrative data.

## Next Steps

* [Configuration]({% link _getting_started/configuration.md %}) implements authentication and authorization.
* [Resources and Fields]({% link _core_features/resources-and-fields.md %}) defines exposure and input semantics.
* [Operations]({% link _core_features/operations.md %}) explains confirmation, receipts and retries.
