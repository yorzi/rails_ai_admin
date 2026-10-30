---
layout: default
title: Template Overrides
nav_order: 5
description: Copy one cataloged admin template and review its source and context compatibility during upgrades.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* How to generate one reviewed host template without replacing an existing file.
* Which assigns and locals form its presentation contract.
* How doctor distinguishes source drift, context drift and unknown metadata.
* How to retain authorization, escaping and confirmation during customization.

## Copy One Cataloged Template

Run the generator inside the host Rails application:

```sh
bin/rails generate rails_ai_admin:override --list
bin/rails generate rails_ai_admin:override field_show
bin/rails rails_ai_admin:doctor
```

The second command creates only
`app/views/rails_ai_admin/fields/_show.html.erb`, beginning with a metadata comment.
Rails uses the host template before the engine default. The
[Template Catalog]({% link _reference/template-catalog.md %}) lists every supported
key, destination and context; the generator accepts keys, not arbitrary paths.
The catalog covers layouts, pages and field partials, including resource
new/edit, member/collection review, selections and jobs. No Surface wrapper key
or ViewComponent-specific adapter is supplied.

Existing host files are preserved even with `--force`. Generator revoke/destroy
also preserves them; remove a reviewed override manually when you choose to
return to the engine default. `--pretend` and `--list` create no files. Unknown
keys, traversal paths, symlink parents/leaves and non-file destinations fail
without replacing an existing override. Creation uses binary source bytes and
exclusive file creation. This protects the copy operation, not the future safety
of arbitrary host changes.

## Use the Template's Explicit Context

For the generated `field_show` partial, a small presentation change can use its
existing authorized text:

```erb
<span class="customer-field"><%= text %></span>
```

Keep the generator's first-line metadata comment above the body. `field_show`
and `field_index` receive `field`, authorized scalar `value` and formatted `text`.
The global `field_form` receives `field`, `form`, `value` and `input_options`;
forward input_options so accessibility attributes reach the input. Registered
field-type form/index/show partials take precedence over these global defaults.
Use [Field Types]({% link _core_features/field-types.md %}) for a per-type choice.

Page contracts list assigns as instance variables, while partial contracts list
locals. An assign may be nil for a particular failure or form flow. A supplied
`@record` is trusted identity/version/policy context, **not an authorized content
projection**. Use `@values`, `@form_values`, permitted field lists or the explicit
projected row/target values for displayed business content; do not read additional
attributes directly from @record. The listed locals/assigns do not form a Ruby
sandbox. Templates still run trusted Rails code and must not perform extra record
lookups or bypass the host's current grants.

Inspect the installed catalog when reviewing an integration:

```ruby
require "rails_ai_admin/templates/catalog"

catalog = RailsAiAdmin::Templates::Catalog.new
entry = catalog.fetch("field_show")
entry.path   # => "rails_ai_admin/fields/_show.html.erb"
entry.locals # => [:field, :value, :text]
entry.assigns # => []
```

Generic resource forms now supply `@form_plan` alongside writable-only
`@form_fields`/`@form_values`. The plan also contains separately authorized
readonly outputs; write-only fields have blank database prefills. Do not rebuild
those outputs from @record. The global `field_row` partial receives `form`, `entry`
and `errors`; it owns editable-versus-readonly rendering, help/error links and
accessibility IDs. Type-specific partials still own their field input/display.

`input_fields` accepts optional `plan` for grouped rendering, falling back to a
writable-only plan from fields/values. `resource_errors` accepts optional `form`
and `fields` locals for summary-to-control links. The resource_new/resource_edit/
resource_form catalog contracts are revision 3; resource_errors/input_fields are
revision 2. Existing older copies require context/source review rather than a
header-only update. See [Resources and Fields]({% link _core_features/resources-and-fields.md %})
for view masks, readonly context and the no-JavaScript fallback.

The `form_recovery` partial has no explicit assigns/locals; it uses the configured
host authentication path within its enclosing raa-form-recovery controller. Keep
notice/message/resume targets and the form's recovery URL/intent/time-zone/current
editable-field data values and Turbo event bindings. The partial alone does not
restore a form. Recovery needs fresh CSRF HTML, the same intent and manual Resume,
then explicit Save; copying an old hidden field must not replace fresh security
metadata. See [Form Session Recovery]({% link _advanced/form-recovery.md %}).

## Preserve Form and Authority Boundaries

Copying a standard template grants no authority. Keep current helper permission
checks, field projections and normal Rails escaping. Do not turn text into raw
HTML with `raw`/`html_safe` or use record getters to rebuild a hidden field.
Layouts must retain the permission-aware navigation helpers, CSRF/CSP metadata,
asset helpers, one document shell and `yield`.

Use normal Rails form helpers and keep CSRF, endpoint/method and server-issued
intent bindings. Retain `intent_ref`, applicable `expected_version`, reviewed
`confirmed_input`, selection refs and member `flow_id` targets. Keep the distinct
review/confirmation/execute steps, stale-form disabled submission and existing
Turbo/dirty-form data attributes. The server still enforces these boundaries,
but an override can mislead a human or break confirmation/retry UX by dropping
its controls.

`resource_new` and `resource_edit` are distinct wrappers. Both explicitly render
the existing `rails_ai_admin/resources/form` template with `layout: false` so the
outer layout is not nested. Preserve that shared form path when adapting the
wrappers; it remains an override key itself. New/edit GET, validation HTTP 422
and stale-version HTTP 409 render their corresponding wrapper. Verify all those
paths after customization, including error text and disabled stale submission.

## Interpret Upgrade Metadata

The generated first line is an ERB comment beginning
`rails_ai_admin:override` and containing a JSON object:

| Header field | Meaning |
| --- | --- |
| `format` | Metadata format, currently integer 1 |
| `key` | Catalog key for this exact destination |
| `gem_version` | Version recorded when the source was copied |
| `source_sha256` | SHA256 of the copied engine source bytes |
| `contract` | Catalog revision of the assigns/locals contract |

The inspector compares header source SHA and contract revision with the installed
catalog. A different gem version alone does not make a copy stale: older version
metadata can remain CURRENT when source bytes and contract revision still match.
Source changes and context-contract changes are independent. The host body is
not hashed or evaluated to certify edits, and metadata is not refreshed
automatically.

Doctor inspects only the standard `app/views/rails_ai_admin` and
`app/views/layouts/rails_ai_admin` namespaces. It does not evaluate host ERB or
inspect custom view paths. Scanning is bounded to 256 `.html.erb` files and 1,024
visited entries; it reads at most 1,024 bytes of a candidate's first header line.
A stopped scan reports INCOMPLETE, not proof that the remaining paths are safe.

| Finding | Doctor status | Meaning |
| --- | --- | --- |
| `CURRENT` | ok | Recorded source/context match; host body edits remain unverified |
| `STALE_SOURCE` | review | Source SHA changed with the same contract revision |
| `STALE_CONTRACT` | review | Assigns/locals contract revision changed |
| `UNTRACKED` | review | A catalog destination has no metadata header |
| `UNCATALOGED` | review | A standard-namespace ERB file has no public catalog entry |
| `INCOMPLETE` | review | Inventory exceeded a bound |
| `INVALID_HEADER` | error | Malformed, oversized, duplicate or incompatible header metadata |
| `UNSAFE_PATH` | error | Symlink, invalid directory/file boundary or unreadable path |

CURRENT is source/context metadata, not a security attestation or certification
of host edits. A manual override can work while remaining UNTRACKED; the status
makes its review gap visible rather than granting it an exception. Custom view
paths remain host-owned review work even when doctor reports no standard override.

## Merge an Upgrade Deliberately

Keep host overrides in the host's normal version control. For an upgrade:

1. Review doctor findings and the installed catalog's source/context changes.
2. Preserve the host body and obtain a clean copy of the newly installed source
   and its generated header in an ignored scratch directory, such as the host's
   root `drafts/`. Ensure that scratch directory is ignored before using it.
3. Compare and manually merge the new source with the reviewed host body, retaining
   permission helpers, projections, escaping, form fields and error paths.
4. Test normal, denied and failure paths in that host, including CSRF,
   confirmation/replay, validation and stale forms as relevant.
5. Only after review, replace the first line with the exact reviewed new header
   bytes matching the source/contract you merged, then run doctor again.

Do not update only the header to hide drift, or expect `--force` to merge or
replace host templates. The generator and inspector provide traceability; the
host owns the customized presentation and its acceptance evidence. This slice
does not complete Phase 2, Surface UI or any full release Gate.

## Next Steps

* [Template Catalog]({% link _reference/template-catalog.md %}) lists exact public context contracts.
* [Field Types]({% link _core_features/field-types.md %}) customizes scalar-specific partials.
* [Operations]({% link _core_features/operations.md %}) explains the confirmation and receipt boundaries to retain.
