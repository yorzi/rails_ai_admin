---
layout: default
title: Template Catalog
nav_order: 7
guide: false
description: Find public override keys, destination paths and explicit Rails context contracts.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

Use `bin/rails generate rails_ai_admin:override --list` for the installed catalog,
then generate one key. Paths below are relative to `app/views/`. Assign names
represent instance variables (for example, context means `@context`); locals are
explicit partial arguments. Values may be nil for a particular request/failure
path. `@record` provides identity/version/policy context, not permission to read
arbitrary attributes. Display business content only from the authorized
projection/form/row/target values supplied by the flow.

This catalog does not make templates a Ruby sandbox or grant action/field
permission. Keep existing authority helpers, escaping, CSRF, intent/confirmation
bindings and failure handling. See
[Template Overrides]({% link _advanced/template-overrides.md %}) for copying,
compatibility statuses and upgrade review. Field-type-specific partials take
precedence over global field defaults. No Surface wrapper is cataloged. Non-HTML plain status responses and host exceptions_app handling remain
outside this ERB template catalog.

The current catalog contains 36 entries; the table below is generated from
`RailsAiAdmin::Templates::Catalog::ENTRIES` and lists each revision.
resource_index is at revision 9 (it adds `bulk_destroy` and `bulk_operations`) and
dashboard at revision 4 (`counts` and `widgets`). New pages for record history,
the audit log, search, CSV import and bulk delete start at revision 1 or, when
they carry list navigation, revision 2. `session_links`
(`rails_ai_admin/shared/_session.html.erb`, empty by default) holds the
signed-in user and sign-out links. Source bytes and context revision
can change independently; always inspect the installed version when upgrading.

resource_errors form/fields locals and input_fields plan are optional.
Generic resource form assigns keep form_fields/form_values writable-only;
form_plan adds separately authorized readonly values (a labelled
`.raa-readonly` group, no longer an `<output>` live region). field_row receives a plan
entry and preserves editable/readonly help/error rendering.

form_recovery has no explicit assigns/locals, but requires its enclosing
raa-form-recovery controller and notice/message/resume targets. Keep the form's
recovery route/intent/time-zone/current editable-field values and Turbo bindings;
its link uses the fixed configured host authentication_path. See
[Form Session Recovery]({% link _advanced/form-recovery.md %}).

Navigation-aware entries receive list_navigation as an immutable plain list
hint, never route/record authority. resource_index also receives sortable_fields,
the currently granted list_scopes, the applied current_scope name (or nil), the
granted filter_fields, bulk_destroy (true when deleting is on and selections are
granted) and bulk_operations (the collection operations the actor may start).
Its `columns` are already ordered by any index settings and `page` reports the
applied sort/direction and optional count; see
[Index Tables]({% link _core_features/index-tables.md %}),
[Named Scopes]({% link _core_features/named-scopes.md %})
and [Typed Filters]({% link _core_features/typed-filters.md %}). Keep nested
list-state hidden fields through `list_state_fields`/`return_navigation_fields`.
Use registered helpers from [List Navigation]({% link _core_features/list-navigation.md %})
and preserve hidden return fields, recovery-header data and discard notices.

status_layout/status_page use revision 1 and render fixed @admin_status with
optional validated @status_sign_in_path, independently of resource navigation.
A failing status override falls back to fixed plain text with the same HTTP
status/session marker. See
[Custom Controllers and Status Pages]({% link _advanced/custom-controllers.md %}).

resource_navigation takes immutable groups from the resource_navigation helper.
Its entry point is cosmetic-only, with no records/counts or stored grants;
legacy visible_resources still includes hidden-menu resources. See
[Resource Navigation]({% link _core_features/resource-navigation.md %}).

| Key | Revision | Destination | Assigns | Locals |
| --- | --- | --- | --- | --- |
| `layout` | 4 | `layouts/rails_ai_admin/application.html.erb` | `context`, `admin_csp_nonce`, `list_navigation` | None |
| `status_layout` | 1 | `layouts/rails_ai_admin/status.html.erb` | `admin_status` | None |
| `status_page` | 1 | `rails_ai_admin/statuses/show.html.erb` | `admin_status`, `status_sign_in_path` | None |
| `session_links` | 1 | `rails_ai_admin/shared/_session.html.erb` | `context` | None |
| `resource_navigation` | 1 | `rails_ai_admin/shared/_navigation.html.erb` | None | `groups` |
| `dashboard` | 4 | `rails_ai_admin/dashboard/index.html.erb` | `context`, `counts`, `widgets` | None |
| `audit_log` | 1 | `rails_ai_admin/audit/index.html.erb` | `context`, `log`, `filters`, `page`, `actor_labels` | None |
| `resource_import` | 1 | `rails_ai_admin/imports/new.html.erb` | `context`, `resource`, `import`, `report`, `problem` | None |
| `search` | 1 | `rails_ai_admin/search/index.html.erb` | `context`, `query`, `sections` | None |
| `resource_index` | 9 | `rails_ai_admin/resources/index.html.erb` | `context`, `resource`, `page`, `columns`, `rows`, `searchable`, `selectable`, `exportable`, `importable`, `sortable_fields`, `list_scopes`, `current_scope`, `filter_fields`, `omitted_rows`, `bulk_destroy`, `bulk_operations`, `list_navigation` | None |
| `resource_show` | 3 | `rails_ai_admin/resources/show.html.erb` | `context`, `resource`, `record`, `values`, `fields`, `operations`, `association_panels`, `list_navigation` | None |
| `resource_history` | 2 | `rails_ai_admin/resources/history.html.erb` | `context`, `resource`, `record`, `history`, `actor_labels`, `list_navigation` | None |
| `resource_associations` | 1 | `rails_ai_admin/resources/_associations.html.erb` | None | `panels` |
| `resource_new` | 5 | `rails_ai_admin/resources/new.html.erb` | `context`, `resource`, `record`, `operation`, `intent_ref`, `form_fields`, `form_values`, `form_plan`, `errors`, `failure_code`, `needs_reload`, `list_navigation` | None |
| `resource_edit` | 5 | `rails_ai_admin/resources/edit.html.erb` | `context`, `resource`, `record`, `operation`, `intent_ref`, `form_fields`, `form_values`, `form_plan`, `errors`, `failure_code`, `needs_reload`, `list_navigation` | None |
| `resource_form` | 5 | `rails_ai_admin/resources/form.html.erb` | `context`, `resource`, `record`, `operation`, `intent_ref`, `form_fields`, `form_values`, `form_plan`, `errors`, `failure_code`, `needs_reload`, `list_navigation` | None |
| `resource_destroy` | 3 | `rails_ai_admin/resources/confirm_destroy.html.erb` | `context`, `resource`, `record`, `intent_ref`, `errors`, `failure_code`, `needs_reload`, `list_navigation` | None |
| `form_recovery` | 1 | `rails_ai_admin/resources/_recovery.html.erb` | None | None |
| `resource_errors` | 3 | `rails_ai_admin/resources/_errors.html.erb` | `errors`, `failure_code`, `needs_reload` | `form`, `fields` |
| `field_index` | 1 | `rails_ai_admin/fields/_index.html.erb` | None | `field`, `value`, `text` |
| `field_show` | 1 | `rails_ai_admin/fields/_show.html.erb` | None | `field`, `value`, `text` |
| `field_reference` | 1 | `rails_ai_admin/fields/_reference.html.erb` | None | `field`, `value`, `reference` |
| `field_form` | 2 | `rails_ai_admin/fields/_input.html.erb` | None | `field`, `form`, `value`, `input_options` |
| `field_row` | 1 | `rails_ai_admin/fields/_row.html.erb` | None | `form`, `entry`, `errors` |
| `input_fields` | 2 | `rails_ai_admin/shared/_input_fields.html.erb` | `resource` | `form`, `fields`, `values`, `errors`, `plan` |
| `operation_form` | 2 | `rails_ai_admin/operations/form.html.erb` | `context`, `resource`, `record`, `definition`, `flow_id`, `form_fields`, `form_values`, `errors`, `failure_code`, `needs_reload`, `list_navigation` | None |
| `operation_confirmation` | 2 | `rails_ai_admin/operations/confirmation.html.erb` | `context`, `resource`, `record`, `definition`, `flow_id`, `proposal`, `form_fields`, `form_values`, `wire_input`, `list_navigation` | None |
| `operation_failure` | 2 | `rails_ai_admin/operations/failure.html.erb` | `context`, `resource`, `failure_code`, `list_navigation` | None |
| `collection_form` | 2 | `rails_ai_admin/collection_operations/new.html.erb` | `context`, `resource`, `definition`, `selection`, `form_fields`, `form_values`, `errors`, `failure_code`, `list_navigation` | None |
| `collection_confirmation` | 2 | `rails_ai_admin/collection_operations/confirmation.html.erb` | `context`, `resource`, `definition`, `proposal`, `wire_input`, `list_navigation` | None |
| `collection_failure` | 2 | `rails_ai_admin/collection_operations/failure.html.erb` | `context`, `resource`, `failure_code`, `uncertain_job_ref`, `list_navigation` | None |
| `job_index` | 1 | `rails_ai_admin/collection_jobs/index.html.erb` | `context`, `jobs` | None |
| `job_show` | 2 | `rails_ai_admin/collection_jobs/show.html.erb` | `context`, `resource`, `job`, `list_navigation` | None |
| `selection` | 2 | `rails_ai_admin/selections/show.html.erb` | `context`, `resource`, `selection`, `operations`, `deletable`, `list_navigation` | None |
| `selection_destroy` | 2 | `rails_ai_admin/selections/confirm_destroy.html.erb` | `context`, `resource`, `selection`, `deletable`, `skipped`, `list_navigation` | None |
| `selection_destroy_result` | 2 | `rails_ai_admin/selections/destroyed.html.erb` | `context`, `resource`, `selection`, `deleted`, `skipped`, `failed`, `list_navigation` | None |
