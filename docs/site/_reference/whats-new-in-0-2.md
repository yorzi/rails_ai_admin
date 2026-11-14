---
layout: default
title: What's New in 0.2
parent: Release History
nav_order: 2
description: Install a working admin in a few commands on Rails 8.1, with generated sign-in, an opt-in trusted-staff policy and multi-model resources.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* Which Rails versions 0.2 supports.
* How the installer connects Rails authentication or Devise.
* When to use the trusted-staff policy preset.
* How to generate resources for many models at once.
* What changed in lists and navigation.
* Where the Public Preview still has limits.

## Rails 8.1 Only

0.2 requires Rails 8.1.4.1 or newer below 8.2, and Ruby 3.3 or newer. Rails 7
and 8.0 are not supported. Upgrade Rails before you upgrade the gem; the
[upgrade guide]({% link _reference/upgrading.md %}) lists the steps.

## Sign-In Connected by the Installer

Connecting an admin to your users used to mean writing a context by hand. The
installer now detects Rails authentication and Devise, generates a working
`AdminContext`, and configures the signed-in name and sign-out button in the
header:

```sh
bin/rails generate rails_ai_admin:install
bin/rails db:migrate
```

The generated context admits users whose `admin?` returns true. A Devise scope
named `admin` or `admin_user` admits every account in that scope, and accounts
that Devise no longer treats as active are rejected. Existing host files are kept, even with
`--force`. [Configuration]({% link _getting_started/configuration.md %}) shows
the header settings.

## An Opt-In Policy for Trusted Staff

The default policy still denies every action and field. For a small team of
trusted staff, pass `--full-access` to start from
`RailsAiAdmin::Authorization::FullAccessAdapter` instead:

```sh
bin/rails generate rails_ai_admin:install --full-access
```

It grants admitted staff every capability that registered resources declare. It
applies no tenant scope or roles, and assistant access stays a separate grant.
Subclass it to narrow records by account, as the
[Quickstart]({% link _getting_started/quickstart.md %}) shows.

## Resources for Many Models at Once

Name several models, namespaced ones included, or pass `--all`:

```sh
bin/rails generate rails_ai_admin:resource Article Billing::Invoice
bin/rails generate rails_ai_admin:resource --all
```

The generator writes one resource file per model and registers it. It suggests
fields, list columns, search, sort, filters, references and child panels from
the schema. Sensitive columns and Rails sign-in sessions are left out, and
models without `updated_at` or `lock_version` stay readonly. A model that
requires a `has_secure_password` password has creating turned off until you
enable its write-only password field. Use `--readonly` to disable writes and
`--no-register` to register resources yourself.
[Getting Started]({% link _getting_started/getting-started.md %}) covers the
options.

## Tidier Lists and Navigation

List titles link to their records, row actions are shorter and timestamps are
compact. On narrow screens the resource menu collapses behind a button.

## Public Preview Limits

* Ruby 3.3 or newer, Rails 8.1.4.1 or newer below 8.2, and SQLite or PostgreSQL.
* Association sorting, polymorphic writes, nested child forms and dedicated
  attach/detach policies are open. Collection selections hold at most 100
  explicitly selected records.
* Chat has a per-person daily message limit. Token and cost budgets and
  automatic conversation retention are open. Live provider behavior and native
  provider APIs still need current verification.
* English ships with the engine. Hosts supply translations for their locales.
  A human screen-reader pass is still open.
* Public Preview contracts may change across 0.x versions. Review template and
  migration changes before updating a host.

See [Development Status]({% link _reference/development-status.md %}) for the
full list, and [What's New in 0.1]({% link _reference/whats-new-in-0-1.md %})
for the workflows inherited from the first preview.

## Next Steps

* [Quickstart]({% link _getting_started/quickstart.md %}) takes an app with Rails 8 sign-in to a working admin.
* [Upgrading]({% link _reference/upgrading.md %}) prepares an existing 0.1 host for 0.2.
* [Compare Rails Admin Gems]({% link _getting_started/comparison.md %}) shows when Rails AI Admin fits.
