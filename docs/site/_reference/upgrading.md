---
layout: default
title: Upgrading
nav_order: 2
guide: false
description: Prepare an existing host for 0.3.0 or 0.2.0 and review earlier migration requirements.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

## Upgrade to 0.3.0 (in development)

0.3.0 needs no migration and no configuration change. Check these if they apply:

* **New filters.** `contains` and `blank` are opt-in per field, for example
  `email :contact, filterable: %i[contains blank]`, and still need the actor's
  `filter` grant. See [Typed Filters]({% link _core_features/typed-filters.md %}).

## Upgrade to 0.2.0

Upgrade Rails to 8.1.4.1 or newer below 8.2 first;
Rails 7 and 8.0 are unsupported. Ruby 3.3+ remains supported.

Existing resources and policies remain explicit. The installer preserves host
files even with `--force`; use it to copy missing migrations. Resource generation
now enables suggested fields, makes versioned models editable and registers them.
Use `--readonly --no-register` to retain manual review before activation.
`--all` skips existing resources. Review generated exposure before using the
opt-in full-access policy; it does not scope records by tenant.

Generated contexts now preserve microseconds in `updated_at` security versions.
Existing custom contexts are not rewritten: use `updated_at.utc.iso8601(6)` if
that timestamp is your authority version. The Devise template also checks
`active_for_authentication?` when resolving users, including background work.

## Earlier Public Preview Migration Notes

For a fresh install, follow the [Quickstart]({% link _getting_started/quickstart.md %}).
If your host already runs a development build, update its gem and copy the current
engine migrations:

```sh
bin/rails generate rails_ai_admin:install --skip
# Only on hosts that already enable Admin Chat:
bin/rails generate rails_ai_admin:assistant --skip
bin/rails db:migrate
bin/rails rails_ai_admin:doctor
```

The native migrations add the record audit index. The optional assistant migrations
add RubyLLM 2.2 storage, streaming draft columns and the MCP access-token table.
The generators preserve migrations already copied to the host.

Review custom layout, overview, list and form overrides. The new styling uses
the existing layout regions plus `raa-list-heading`, `raa-list-toolbar`,
`raa-dashboard-intro` and `raa-record-form` classes. Bring those classes into any
override that should adopt the new styles.

Resources cannot use the reserved keys `search` or `mcp`. Registered custom
field types named `email`, `url`, `time`, `json` or `password` must be renamed.
Models that use `updated_at` for write versioning cannot declare it writable.

The operation fingerprint now includes the explicit resource policy mapping.
Existing development intents from before this change can return
`APPROVAL_INVALIDATED`. Reopen their forms and review current permissions; do not
recreate or edit persisted receipts to force execution.

## Changes From the Public Preview Preparation (2026-11-13)

* Engine templates now read their text from `config/locales/en.yml`. The
  English output is unchanged, so template contracts keep their revisions, but
  doctor reports source drift for every overridden template. Review each one;
  copying the new `t("rails_ai_admin.…")` calls into an override makes it
  translatable. A `layout` override should add
  `data-raa-messages="<%= t("rails_ai_admin.script").to_json %>"` to `<body>`
  so the form-recovery and unsaved-changes messages follow the locale.
* Reference inputs past 100 targets render the new
  `rails_ai_admin/fields/_reference_picker` partial around the key input. An
  overridden `field_form` that calls `admin_reference_input` gets it
  automatically.

## Changes From the 2026-11-10 Audit Work

* Native form pages no longer create an `OperationRun`; `intent_ref` is a signed
  form reference until the first submit (ADR 0025). Host tests that looked up
  `OperationRun.find(form_value)` should use
  `RailsAiAdmin::Operations::FormIntent.id_for(form_value)`, and expect a run only
  after a submit. Rotating `secret_key_base` invalidates open forms.
* Template contracts changed: `resource_new`, `resource_edit` and `resource_form`
  (revision 5) and `resource_destroy` (3) render `@intent_ref` instead of
  `@intent`; `resource_index` (6) adds `@omitted_rows`; `resource_errors` (3)
  shows outcome sentences; `layout` (4) adds page titles, the environment label
  and the new `session_links` partial. Regenerate or review overrides that doctor
  reports as stale.
* Blank text is null in nullable fields and "cannot be blank" in required or
  non-null ones; `required: true` also rejects null. Text input rejects control
  characters. Decimals reject digits beyond the column's scale or precision.
* `required` and model validation messages now reach the page; set
  `config.validation_messages = :generic` for the earlier behaviour.
* `search_records` in Admin Chat no longer applies a default list tab, and its
  values are typed (`PROMPT_VERSION` 2). The chat enforces
  `assistant_daily_message_limit` (100 by default).
* A delete blocked by references returns `RESTRICTED`, not `CONFLICT`.
* Admin jobs use `config.queue_name`; Surfaces need a resolvable rails_tool_views
  `parent_controller` at boot.
* Pages address records only by canonical primary-key text, and routes no longer
  accept a format suffix.
* With `config.authentication_path` set, a signed-out page visit (a plain HTML
  GET) now redirects with 303 to that path plus `return_to`, instead of a 401.
  Form submissions, recovery, frames and non-HTML requests still get 401. Update
  host tests that expected a 401 for a page visit.
* 0.1 supported Ruby 3.3+ and Rails 8.0.5.2 to below 8.2.
  0.2 requires Rails 8.1.4.1+ below 8.2.
  Engine migrations declare `ActiveRecord::Migration[8.0]`; on Rails 8.1 that
  produces the same schema, so a host that already ran them changes nothing.
* Re-running `rails_ai_admin:install` or `rails_ai_admin:assistant`, with or
  without `--force`, keeps engine migrations already in `db/migrate`. If an
  earlier forced run replaced one under a new timestamp, delete the new copy
  before `db:migrate`.
* The gemspec no longer depends on `ruby_llm` or `rails_tool_views`. A host that
  enables `config.assistant` or `config.surfaces` must list the gem in its own
  Gemfile; boot reports a missing gem or a version outside the supported range.
* Admin Chat needs `ruby_llm` 2.2.0 or later. Update the gem, run
  `bin/rails generate rails_ai_admin:assistant` again to copy the new
  `upgrade_rails_ai_admin_assistant_to_ruby_llm_2_2` migration, then
  `bin/rails db:migrate`. It adds RubyLLM 2.2's columns and tables, skipping any
  that exist. If your app has its own RubyLLM chats, also run RubyLLM's
  `ruby_llm:upgrade` generator for them, as its upgrade guide describes.

Back up the host database, test migrations against a disposable copy, run the host
policy matrix and verify packaged installation before using a changed build.
Never delete live operation receipts to get a replay to execute again. Keep
pending/unknown outcomes and the full supported retry window intact.

Review the [Public Preview limits]({% link _getting_started/whats-new-in-0-2.md %}#public-preview-limits)
and run the host's authentication and authorization tests before deploying.
