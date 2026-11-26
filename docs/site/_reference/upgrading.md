---
layout: default
title: Upgrading
nav_order: 2
guide: false
description: Apply development-line migrations, update host template overrides and configure grants for new features.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

## Upgrade from 0.5.0 to the 0.9.0 development line

Run `bin/rails generate rails_ai_admin:install --skip`, `bin/rails db:migrate` and `bin/rails rails_ai_admin:doctor`. There are eight new migrations since 0.5.0. The last three install saved queries, recipes and recipe runs, and encrypted import rows. The gem adds `fugit` to evaluate five-field cron expressions.

For template overrides, compare the current resource index (revision 11), dashboard (5) and import form (3) to your host copies. The upload form uses `@review.limit`. The layout remains at contract 7. Check the earlier milestone notes below for other affected templates.

Schedule `bin/rails rails_ai_admin:imports:scan` and `bin/rails rails_ai_admin:recipes:scan` for the background features you enable. Run an Active Job worker and keep the prune task scheduled. Background imports require a context adapter with `resolve_job`. Hosts without it keep synchronous review up to 100 rows. Sharing reports requires `share_reports?`. Recipe owners and principals require `run_recipe?` and assistant access. Reviewers need the operation and approval grants. [Recipes]({% link _advanced/recipes.md %}).

## 0.8.0 milestone

The 0.6, 0.7 and 0.8 milestones are included in the 0.9.0 development line.

**Import drafts.** For staged CSV review, run `bin/rails generate rails_ai_admin:install --skip` and `bin/rails db:migrate` to install the import-drafts table. If your host overrides `resource_import`, update its upload form to template revision 2 to expose **Review CSV import**. Schedule `bin/rails rails_ai_admin:prune` to delete expired drafts. The review uses the existing import and create grants. [CSV export and import]({% link _core_features/csv-export.md %}).

**Data quality rules.** No migration. Register rules in `config.quality_rules` and grant each one with `run_quality_rule?(context:, resource:, rule:)`; every preset, including `FullAccessAdapter`, denies it. If you copied `resources/index.html.erb`, add the **Data quality** link shown when `@quality_rules_available` is true, as in the default template, and set the header's `contract` to 10. A rule's evidence must name declared, visible scalar fields, or the check raises `ConfigurationError`. [Data Quality Rules]({% link _core_features/data-quality.md %}).

## Upgrade to 0.7.0

This section describes the 0.7 milestone on `main`. It includes every 0.6.0 change below.

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

**Operation confirmation overrides.** `operation_confirmation` and
`collection_confirmation` are revision 3. The defaults hide Confirm from the
proposer of an operation that needs another approver and link to its task, and
the collection page states the full target count (`@proposal.total_count`) with
a notice when only a sample is previewed or a retry left records out. A copied
template still works, but it shows a Confirm button the server refuses for such
proposers and counts only the previewed records; copy the new defaults and set
the header's `contract` to 3.

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

0.6.0 was not released on its own; its changes ship in the next release from `main`. Run these commands from the host application.

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
