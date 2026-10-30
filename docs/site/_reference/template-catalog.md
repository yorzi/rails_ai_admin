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

The current catalog contains 26 entries. resource_new/resource_edit/resource_form
use contract revision 4; other navigation-aware templates and resource_errors/input_fields
use revision 2; remaining entries use revision 1. Source bytes and context revision
can change independently; always inspect the installed version when upgrading.

resource_errors form/fields locals and input_fields plan are optional.
Generic resource form assigns keep form_fields/form_values writable-only;
form_plan adds separately authorized readonly output. field_row receives a plan
entry and preserves editable/readonly help/error rendering.

form_recovery has no explicit assigns/locals, but requires its enclosing
raa-form-recovery controller and notice/message/resume targets. Keep the form's
recovery route/intent/time-zone/current editable-field values and Turbo bindings;
its link uses the fixed configured host authentication_path. See
[Form Session Recovery]({% link _advanced/form-recovery.md %}).

Navigation-aware entries receive list_navigation as an immutable plain list
hint, never route/record authority. resource_index also receives sortable_fields.
Use registered helpers from [List Navigation]({% link _core_features/list-navigation.md %})
and preserve hidden return fields, recovery-header data and discard notices.

status_layout/status_page use revision 1 and render fixed @admin_status with
optional validated @status_sign_in_path, independently of resource navigation.
A failing status override falls back to fixed plain text with the same HTTP
status/session marker. See
[Custom Controllers and Status Pages]({% link _advanced/custom-controllers.md %}).

| Key | Revision | Destination | Assigns | Locals |
| --- | --- | --- | --- | --- |
| `layout` | 2 | `layouts/rails_ai_admin/application.html.erb` | `context`, `admin_csp_nonce`, `list_navigation` | None |
| `status_layout` | 1 | `layouts/rails_ai_admin/status.html.erb` | `admin_status` | None |
| `status_page` | 1 | `rails_ai_admin/statuses/show.html.erb` | `admin_status`, `status_sign_in_path` | None |
| `dashboard` | 1 | `rails_ai_admin/dashboard/index.html.erb` | `context` | None |
| `resource_index` | 2 | `rails_ai_admin/resources/index.html.erb` | `context`, `resource`, `page`, `columns`, `rows`, `searchable`, `selectable`, `sortable_fields`, `list_navigation` | None |
| `resource_show` | 2 | `rails_ai_admin/resources/show.html.erb` | `context`, `resource`, `record`, `values`, `fields`, `operations`, `list_navigation` | None |
| `resource_new` | 4 | `rails_ai_admin/resources/new.html.erb` | `context`, `resource`, `record`, `operation`, `intent`, `form_fields`, `form_values`, `form_plan`, `errors`, `failure_code`, `needs_reload`, `list_navigation` | None |
| `resource_edit` | 4 | `rails_ai_admin/resources/edit.html.erb` | `context`, `resource`, `record`, `operation`, `intent`, `form_fields`, `form_values`, `form_plan`, `errors`, `failure_code`, `needs_reload`, `list_navigation` | None |
| `resource_form` | 4 | `rails_ai_admin/resources/form.html.erb` | `context`, `resource`, `record`, `operation`, `intent`, `form_fields`, `form_values`, `form_plan`, `errors`, `failure_code`, `needs_reload`, `list_navigation` | None |
| `resource_destroy` | 2 | `rails_ai_admin/resources/confirm_destroy.html.erb` | `context`, `resource`, `record`, `intent`, `errors`, `failure_code`, `needs_reload`, `list_navigation` | None |
| `form_recovery` | 1 | `rails_ai_admin/resources/_recovery.html.erb` | None | None |
| `resource_errors` | 2 | `rails_ai_admin/resources/_errors.html.erb` | `errors`, `failure_code`, `needs_reload` | `form`, `fields` |
| `field_index` | 1 | `rails_ai_admin/fields/_index.html.erb` | None | `field`, `value`, `text` |
| `field_show` | 1 | `rails_ai_admin/fields/_show.html.erb` | None | `field`, `value`, `text` |
| `field_form` | 1 | `rails_ai_admin/fields/_input.html.erb` | None | `field`, `form`, `value`, `input_options` |
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
| `selection` | 2 | `rails_ai_admin/selections/show.html.erb` | `context`, `resource`, `selection`, `operations`, `list_navigation` | None |
