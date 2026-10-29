---
layout: default
title: Host Verification
nav_order: 1
description: Verify your host adapters and installation boundaries with focused checks.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* How to run doctor without a provider call.
* How to assert policy and tenant boundaries from host tests.
* Which evidence still needs browser and packaged-host verification.

## Run Installation Diagnostics

```sh
bin/rails rails_ai_admin:doctor
```

Doctor reports configured context/policy status, connection-pool and optimistic
locking requirements for registered resources, and unsupported assistant, private
file and durable-queue capabilities. A configured adapter is marked for review,
not declared secure merely because its class exists. Error findings fail the task.
For Pundit resources, doctor also reports whether the explicit policy class and
its policy-owned/inherited Scope can be resolved. A complete mapping is only
metadata: it does not prove the Scope, action predicates or field grants are
correct. Doctor neither probes credentials nor calls providers.

## Assert Host Policy Decisions

The framework-neutral test kit raises `RailsAiAdmin::TestKit::AssertionError` on a
failed assertion. Given your authenticated `context`, a record `customer` in its
tenant and `other_customer` from another tenant:

```ruby
require "rails_ai_admin/test_kit"

RailsAiAdmin::TestKit.assert_access(
  context: context, resource: CustomerAdmin,
  action: :update, record: customer, allowed: true
)
RailsAiAdmin::TestKit.assert_isolated(
  context: context, resource: CustomerAdmin,
  foreign_id: other_customer.id
)
RailsAiAdmin::TestKit.assert_hidden(
  context: context, resource: CustomerAdmin, field: :secret
)
```

Run the same matrix for anonymous users, readers, writers, different tenants and
revoked sessions. These helpers cover initial access, complete SQL scope and field
exposure. They do not automatically prove every future export, association, AI
query or stream. Those features are not present yet.

## Verify Beyond an In-Repository Test App

For the development package, verify install/migrate/boot and CRUD from the built
`.gem`, with no repository path dependency. Check `zeitwerk:check`, production
eager load and asset precompilation. Validate the host's own `Ai` constant still
uses the normal Rails inflector. Run SQLite and PostgreSQL separately; a passing
SQLite run does not prove PostgreSQL locking behavior.

In a browser, run the no-JavaScript CRUD path, then Turbo/Stimulus navigation,
validation and failed-network recovery. Check keyboard operation, narrow viewports,
light/dark presentation and the Content Security Policy console. Automated checks
and internal review do not replace independent human accessibility/security review.

## Exercise the Independent Devise Consumer

`spec_hosts/devise_postgres` is a separate packaged support application, not a
configuration switch on the native-session SQLite host. It uses host-owned Devise
sessions and Pundit policies, verified tenant memberships, UUID tickets,
PostgreSQL and jsbundling. Its consumer script installs the built gem, runs real
migrations, acceptance tests, `zeitwerk:check`, production eager load and asset
precompilation. Propshaft and Sprockets are separate asset modes of that same Host B;
they do not count as a third independent consumer.

Set `RAA_HOST_B_DATABASE_URL` in your test environment to a **disposable** PostgreSQL
database whose name ends in `_test`. Do not pass a production URL. Then run:

```sh
bundle exec rake build
bundle exec ruby script/packaged_support_smoke.rb
bundle exec ruby script/packaged_recovery_smoke.rb
```

For Sprockets plus jsbundling, set the non-secret `RAA_ASSET_PIPELINE=sprockets`
option for both consumer scripts. The test fixtures use synthetic credentials and
keys. The recovery script changes real source files inside the isolated packaged
copy to exercise Rails reload, and kills a child at a confirmed transaction crash
point before verifying rollback/replay from fresh processes. It cleans up its child
processes. These are destructive test probes; use only the disposable fixture.

The fixture also has a separate host `ProductChat` and product-owned
`rails_tool_views` Surface. Conventional admin requests preserve their provider
configuration, resolver and ownership boundaries. This does not establish admin
Chat/Surface continuation support. No real provider call or key is used.

Consult the checkout's `COMPATIBILITY.md` for final executed combinations; test
source and configured scripts alone are not proof that a run passed. Full release
Gates A through E remain open.

## Next Steps

* [Pundit and Devise]({% link _advanced/pundit-and-devise.md %}) documents the host integration contract.
* [Data and Security]({% link _advanced/data-and-security.md %}) describes operational constraints.
* [Development Status]({% link _reference/development-status.md %}) keeps release gates distinct from tests.
