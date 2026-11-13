---
layout: default
title: Upgrading
nav_order: 2
guide: false
description: Review development contract and storage changes before replacing a local build.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

No stable gem has been released. Development APIs and migrations can still change;
read the checkout's `CHANGELOG.md` and public contract before replacing a local build.
Do not infer that an unchanged `0.1.0.dev` identifier guarantees compatible storage.

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
* The supported range is now Ruby 3.3+ and Rails 8.0.5.2 to below 8.2.
  Engine migrations declare `ActiveRecord::Migration[8.0]`; on Rails 8.1 that
  produces the same schema, so a host that already ran them changes nothing.
  Rails 8.0 hosts keep `json` below 3.
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

A future stable release must document SemVer, supported combinations, migration
and rollback limits, release notes and explicit owner approval. This page does not
approve deployment or publication.
