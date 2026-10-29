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

The runtime requires Ruby 3.4 or newer and Rails 8.1.4 to below 8.2. The dependency
range does not prove every combination has passed; consult `COMPATIBILITY.md` in
the checkout for executed evidence. Generic writes target SQLite and PostgreSQL.

## Install the Closed Engine

In the host:

```sh
bundle install
bin/rails generate rails_ai_admin:install
bin/rails db:migrate
bin/rails generate rails_ai_admin:resource Customer
bin/rails rails_ai_admin:doctor
```

The install generator copies conventional execution/audit migrations, a configuration
initializer and `app/rails_ai_admin/admin_context.rb`. It mounts the engine at
`/admin` with the name `rails_ai_admin`. The generated context returns `nil`, the
default policy denies every action, and the resource generator emits a readonly
resource exposing only its ID. An authenticated host user receives no automatic
permission.

The generator does not create users, roles, provider settings or assistant tables.
It leaves existing conflicting files for your review; do not force an overwrite
of a configured host adapter.

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

## Enable Reviewed Fields

Replace the generated resource after reviewing the host model and policy:

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
