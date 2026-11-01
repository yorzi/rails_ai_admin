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
* How to assert anonymous access, actions and tenant boundaries from host tests.
* How to compare exact independent field grants.
* Which evidence still needs browser and packaged-host verification.

## Run Installation Diagnostics

```sh
bin/rails rails_ai_admin:doctor
```

Doctor reports context/policy public interfaces, connection-pool and optimistic
locking requirements, schema metadata, sensitive declarations and the default
host autoload path. It identifies unimplemented assistant/private-file capability
and reports registered Work, its auto-dispatch setting and required scan/queue
review. Work does not establish asynchronous business execution. A complete interface is marked for review, not
declared secure merely because its methods exist. Error findings fail the task.

For a context adapter, it checks for public `resolve`; for a policy adapter, public
`scope`, `allowed?` and `fields`. It also checks that public `.new` accepts no
arguments and flags obviously incompatible `initialize` and positional/keyword
method signatures as errors. These are signature checks, not proof that the
constructor body or adapter behavior is correct. Pundit mapping checks separately resolve the named
policy and its policy-owned/inherited Scope. None of these metadata checks proves
anonymous denial, SQL membership, action decisions or field grants.

Schema diagnostics identify declared fields without supported scalar columns
(including missing, array or unsupported JSON columns). This does not establish
all Field/database type conversions. `field_types:<resource>` marks obvious scalar
Field/database mismatches for review; an `ok` metadata result does not prove every
format, precision or conversion. Sensitivity diagnostics flag naming heuristics
(including authority-like names) and encrypted attributes for review.

For declared sortable fields, doctor reports missing leading-column indexes;
check real query plans and tenant-composite indexes yourself. The hint does not
create an index or establish performance. The default-path check reports whether
`app/rails_ai_admin` is an autoload root and whether Rails' `RailsAiAdmin` inflection
is preserved. Custom `host_paths` configuration is not implemented.

For registered Work, doctor also checks the job-context resolver interface and
flags delivery/receipt policy review. For custom operations it validates handler
metadata and declared atomic-model pools; neither proves preflight purity,
external-effect safety or a hard deadline.

Doctor does not call `resolve` to simulate a real anonymous session, sample business
records, probe credentials, invoke a provider or prove callback safety. Use host
request tests and the independent TestKit checks below.

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

## Assert the Anonymous Boundary

Installation supplies `test/rails_ai_admin/access_test.rb`. Run it before and
after replacing the closed generated adapters:

```sh
bin/rails test test/rails_ai_admin/access_test.rb
```

It requests the named mount without authenticating and expects an unauthorized
response. Adapt the test to the host's anonymous session/Devise failure behavior
when wiring real authentication; do not replace the denied boundary with a
success assertion merely to make the test pass.

For a direct adapter check, supply a host controller/request object representing
an anonymous session as `anonymous_controller`:

```ruby
RailsAiAdmin::TestKit.assert_unauthenticated(
  adapter: AdminContext.new,
  controller: anonymous_controller
)
```

This helper calls `resolve(controller)` and requires exactly `nil`, not any
truthy/falsey substitute. It does not make an HTTP request or establish how a real
session, middleware or redirect behaves. Keep both the direct and request tests.

## Compare Independent Field Grants

Given the administrator context, Customer resource and custom policy shown in the
configuration guide, compare the exact grants:

```ruby
expected = {
  "read" => %w[active id name points],
  "write" => %w[active name points],
  "search" => %w[name],
  "sort" => %w[name],
  "filter" => []
}
RailsAiAdmin::TestKit.assert_field_grants(
  context: context,
  resource: CustomerAdmin,
  record: customer,
  operation: :update,
  expected: expected
)
```

Use a representative record when field rules depend on record state. The helper
requires all four groups and compares their exact membership after normalizing
keys/field names to strings and sorting; it does not treat `expected` as a minimum
allowlist. An unexpected newly granted field therefore fails the snapshot.

To inspect the same structure without an assertion:

```ruby
grants = RailsAiAdmin::TestKit.field_grants(
  context: context,
  resource: CustomerAdmin,
  record: customer,
  operation: :update
)
```

The result always has string keys `read`, `write`, `search` and `sort`, with sorted
field-name string arrays. `operation` accepts `:create` or `:update` and selects
new/edit write exposure; its default is `:update`. No record values are returned.

These are independent field grants after policy/DSL intersection. The snapshot
does not apply action permission or SQL membership, and a supplied record is not
made authorized by producing a snapshot. Keep `assert_access`, `assert_isolated`
and real requests alongside it. It is not an AI exposure report: assistant tools,
query capabilities and record projections are separate concerns. Custom operation
inputs, receipt reads and Work delivery also have independent grants outside this
four-group snapshot. Test them through their own operation/delivery paths.

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

When enabling custom operations/Work, additionally exercise input-bound preflight,
replay after a successful state transition, revoked receipt/delivery permissions,
missed enqueue recovery and unknown downstream outcomes. A stable mock receipt
does not prove a real downstream system honors its delivery key. Consult the
[Outbox contract]({% link _advanced/durable-outbox.md %}) before making that claim.

## Next Steps

* [Durable Outbox]({% link _advanced/durable-outbox.md %}) defines scanning, fencing and reconciliation boundaries.
* [Pundit and Devise]({% link _advanced/pundit-and-devise.md %}) documents the host integration contract.
* [Data and Security]({% link _advanced/data-and-security.md %}) describes operational constraints.
* [Development Status]({% link _reference/development-status.md %}) keeps release gates distinct from tests.
