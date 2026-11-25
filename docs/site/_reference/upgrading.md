---
layout: default
title: Upgrading
nav_order: 2
guide: false
description: Upgrade an existing 0.5 host to the 0.7 development line, apply its migrations, update layout overrides and add the new approval, undo and tasks grants.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

## Upgrade to 0.7.0

0.7.0 is in development on `main`; this section describes that branch. It
includes every 0.6.0 change below, so a 0.5.0 host applies both sections.

```sh
bundle update rails_ai_admin
bin/rails generate rails_ai_admin:install --skip
bin/rails db:migrate
bin/rails rails_ai_admin:doctor
```

The installer copies four migrations. They add approval, verification and undo
columns to `rails_ai_admin_operation_runs` and the proposer to
`rails_ai_admin_audit_events`, raise the selection and batch item limits from
100 to 10,000 rows (with `retry_of_run_id`), and create
`rails_ai_admin_tasks` and `rails_ai_admin_task_events`. Existing rows keep
their meaning: old runs are `:self` runs with no verification or undo. On
SQLite the limit migration rebuilds three tables. Until the migrations run,
operations that need a second approver raise `ConfigurationError` and the
Tasks page stays hidden; everything else works as before.

**Layout overrides.** The `layout` contract is revision 7 and adds the
**Tasks** link. If you copied `layouts/rails_ai_admin/application.html.erb`,
add `<% if tasks_available? %><%= link_to tasks_nav_label, admin_tasks_path %><% end %>`
to the header navigation, as in the default layout, and set the header's
`contract` to 7.

**New grants, all denied until you add them.** `approve_operation?` to approve
another person's proposal, `undo_operation?` to undo, and `view_tasks?` for the
Tasks page. `FullAccessAdapter` grants `undo_operation?` and `view_tasks?`, but
never `approve_operation?`. See
[Approvals, Verification and Undo]({% link _core_features/approvals-and-undo.md %})
and [Tasks and Approvals]({% link _core_features/tasks.md %}).

**Background collection jobs.** A worker job now processes
`config.async_bulk_chunk_size` items (default 50, was 100) and enqueues the next
job itself after a full chunk. Keep the recurring
`rails_ai_admin:collections:scan` schedule as the recovery backstop. The inline
drain task still handles up to 100 items per run.

**Assistant bulk changes.** `propose_bulk_change` can now select up to
`config.async_bulk_limit` records by query or filters (1,000 by default).
Lower the limit if your reviewers should not confirm that many at once.

## Upgrade to 0.6.0

0.6.0 was not released on its own; its changes ship with 0.7.0.

Set `gem "rails_ai_admin", "~> 0.6.0"` in your Gemfile once it is released, then
run these commands from the host application.

```sh
bundle update rails_ai_admin
bin/rails rails_ai_admin:doctor
```

There is no new migration. Install 0.5.0 and run its migration first if the
host is on 0.4.x or earlier.

**Layout overrides.** The `layout` contract is revision 6 and adds the
assistant drawer. If you copied `layouts/rails_ai_admin/application.html.erb`,
the doctor reports it as `STALE_CONTRACT`. Where `assistant_available?` is true
outside the assistant's own pages, add `data-controller="raa-drawer"` to
`<body>`, the header's `raa-drawer-toggle` button and
`<%= render "rails_ai_admin/assistant/drawer" %>` after `<main>`, as in the
default layout, and set the header's `contract` to 6. Without them the pages
work; they only lack the drawer. See
[Template Overrides]({% link _advanced/template-overrides.md %}).

**Relation filters.** The assistant and MCP can now filter one resource through
a declared `belongs_to` field or `has_many`/`has_one` panel. They use the
related resource's scope, soft delete, `assistant?` grant and filter grants, so
review the filter grants of resources reached that way.

**Bulk change review overrides.** The review page now holds the rows, the edited
values and the decisions in one form. A host copy of
`bulk_changes/show.html.erb` that submits no `target_ids[]` keeps confirming
every ready record; copy the new template to offer narrowing and editing.

## Upgrade to 0.5.0

Set `gem "rails_ai_admin", "~> 0.5.0"` in your Gemfile and run these commands
from the host application.

```sh
bundle update rails_ai_admin
bin/rails generate rails_ai_admin:install --skip
bin/rails db:migrate
bin/rails rails_ai_admin:doctor
```

The installer copies `add_missing_indexes_to_rails_ai_admin_tables`, which only adds indexes. Install 0.4.1 and run its migration first if the host is on 0.4.0 or earlier.

**Bulk delete overrides.** The `selection_destroy` contract is revision 3. The confirmation now submits a signed `review_signature` of the records it showed, and a submission without it is refused. If you copied `selections/confirm_destroy.html.erb`, the doctor reports it as `STALE_CONTRACT`. Add `<%= hidden_field_tag :review_signature, @review_signature, id: nil %>` to its form and set the header's `contract` to 3.

**Stricter checks.** These declarations worked before and now fail early or deny:

- A Pundit policy method must return exactly `true` to grant. One that returns another truthy value, such as a record or a string, now denies.
- `searchable:` is allowed on text, textarea, email, url, enum, select and belongs_to fields only, with `true`, `:prefix`, `:contains` or `:exact`. Remove it from other fields; loading the resource raises `ConfigurationError` until then.
- A Work handler's `lease_duration` must be longer than its `max_duration`.
- Restore runs the model's validations, so a record that no longer validates stays deleted.

**Assistant and MCP grants.** Review policies for resources reached through a
reference. Chat and MCP now require `assistant?` on the target resource to
resolve its label or search or sort through it. An MCP token stops working when
its owner loses the assistant grant on every resource.

**Layout overrides.** The `layout` contract is revision 5. If you copied
`layouts/rails_ai_admin/application.html.erb`, the doctor reports it as
`STALE_CONTRACT`. Add `<%= admin_rich_text_assets %>` to its head and set the
header's `contract` to 5; see
[Template Overrides]({% link _advanced/template-overrides.md %}). Until then,
Trix keeps loading beside each editor, and an editor opened by a Turbo visit
can show its link dialog open.

**Prompt caching.** The assistant sends cache hints to the provider by default.
If your adapter points the `openai` provider at a compatible server that rejects
fields it does not know, set `config.assistant_prompt_caching = false`.

**Optional additions.** These are all opt-in:

* `instructions(context:)` on the assistant adapter, for operator notes.
* `config.assistant_fallback_models`, for up to three fallback models.
* `period` grouping, available for any date or datetime field the person may
  filter by. It needs no setup beyond that filter grant.
* An evaluation file. `bin/rails generate rails_ai_admin:assistant` writes
  `config/rails_ai_admin/assistant_eval.yml` when it is missing, and keeps your
  adapter and migrations; then run `bin/rails rails_ai_admin:assistant:eval`.

See [What's New in 0.5]({% link _reference/whats-new-in-0-5.md %}) and the
[Admin Assistant]({% link _advanced/admin-assistant.md %}) guide.

If you are upgrading from an earlier version, see the
[0.4.1 upgrade guide](https://github.com/yorzi/rails_ai_admin/blob/v0.4.1/docs/site/_reference/upgrading.md).
For a new installation, follow the [Quickstart]({% link _getting_started/quickstart.md %}).
