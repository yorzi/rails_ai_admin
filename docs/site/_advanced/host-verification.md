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
Doctor neither probes credentials nor calls providers.

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

## Next Steps

* [Data and Security]({% link _advanced/data-and-security.md %}) describes operational constraints.
* [Development Status]({% link _reference/development-status.md %}) keeps release gates distinct from tests.
