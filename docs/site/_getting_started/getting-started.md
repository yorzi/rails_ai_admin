---
layout: default
title: Getting Started
nav_order: 2
description: Install the gem and connect a closed admin engine to your host.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

For the shortest path from an app with sign-in to a working Users admin, follow
the [Ten-Minute Quickstart]({% link _getting_started/quickstart.md %}).

After reading this guide, you will know:

* How to install the gem in a host application.
* How to mount the engine and register a resource.
* Which host contracts you must implement before enabling access.

## Install the Gem

{% if site.docs_unreleased %}
Build the package from this checkout:

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
{% else %}
Add this to the host app's Gemfile:

```ruby
gem "rails_ai_admin", "{{ site.version }}"
```
{% endif %}

The runtime requires Ruby 3.3+ and Rails 8.1.4.1+ below 8.2. Rails 7 and
8.0 are unsupported. CI covers Ruby 3.3 and 4.0 on SQLite and PostgreSQL;
`COMPATIBILITY.md` records executed evidence for specific combinations.

## Install the Closed Engine

In the host:

```sh
bundle install
bin/rails generate rails_ai_admin:install
bin/rails db:migrate
bin/rails generate rails_ai_admin:resource Customer
bin/rails rails_ai_admin:doctor
```

The installer copies conventional execution/audit migrations, an initializer,
`AdminContext`, a default-deny `AdminPolicyAdapter`, and an anonymous access test.
It detects Rails authentication or Devise and connects the context to existing
sign-in; unknown sign-in systems get a closed context. It adds `/admin` only if
there is no existing engine mount. Authenticated users still need policy grants.

`--full-access` opts into the trusted-staff preset described in the
[quickstart]({% link _getting_started/quickstart.md %}). It applies no tenant scope.
Installation preserves existing initializer, context, policy and access-test
files, even with `--force`. Rerunning copies missing migrations and files only.
Run it inside the target Rails app so it can inspect the actual routes. Conflicting
constants and mount aliases are rejected before writing. The installer creates
no users, provider settings or assistant tables.

Run `bin/rails test test/rails_ai_admin/access_test.rb` before and after changing
host authentication. An anonymous test alone does not prove your tenant boundary.

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

`rails_ai_admin:resource Customer` writes and registers a resource from schema
metadata. Supported fields are enabled, with search, sort, filter and list settings.
It reads no business records. Sensitive names, encrypted attributes, raw foreign
keys, tenant/authority columns and unsupported types are omitted. References are
enabled when their target resources are registered or generated together.

Generate several models with `rails_ai_admin:resource Customer Order`, or use
`--all` for models under `app/models`. Existing resources and Rails sign-in sessions
are skipped by `--all`. Namespaced models are supported. Use `--readonly` for
read-only setup and `--no-register` for manual registration.

For a single model, select schema suggestions explicitly:

```sh
bin/rails generate rails_ai_admin:resource Customer --fields name:text points active
```

Other suggestions remain commented. Sensitive or unsupported names and mismatched
types are rejected. Unknown models and unavailable tables produce unregistered
readonly stubs. Models without `updated_at` or `lock_version` remain readonly.
Review field meaning: a harmless name does not prove nonsensitive contents.

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
and the usual `created_at`/`updated_at` timestamps. Your policy supplies tenant
scoping. Every write checks that the record has not changed since the form was
opened: through `lock_version` when the model uses Rails optimistic locking,
otherwise through `updated_at`. A table with neither needs one of them before
generic writes are enabled.

Keep the resource `readonly` if callbacks send mail, call remote services or cause
other effects that cannot roll back with the database. Run doctor and host tests
before using even the development build with administrative data.

## Next Steps

* [Configuration]({% link _getting_started/configuration.md %}) implements authentication and authorization.
* [Resources and Fields]({% link _core_features/resources-and-fields.md %}) defines exposure and input semantics.
* [Operations]({% link _core_features/operations.md %}) explains confirmation, receipts and retries.
