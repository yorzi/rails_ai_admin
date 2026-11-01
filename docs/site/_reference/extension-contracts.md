---
layout: default
title: Extension Contracts
nav_order: 6
guide: false
description: Check the supported scalar field extension signatures and trust boundaries.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

The current extension surface refines explicit scalar fields and supports bounded
readonly computations from declared authorized dependencies. It does not expose
arbitrary record lookup, a field/computation extension generator or a
ViewComponent-specific adapter. Cataloged page/layout/partial copies use the
separate [Template Overrides]({% link _advanced/template-overrides.md %}) contract. Start with
[Field Types]({% link _core_features/field-types.md %}) and
[Computed Fields]({% link _core_features/computed-fields.md %}).

## Registration and Declaration

`config.field_types` maps stable String/Symbol keys to class-name Strings. Keys
match `[a-z][a-z0-9_]{0,39}`, cannot duplicate after string normalization and cannot
replace a built-in type. The resolved class must be a named subclass of
`RailsAiAdmin::Fields::Type` with a compatible public zero-argument `.new` and
initializer. Resources and operation input blocks use
`field :attribute, type: :registered_key, **options`; built-in DSL methods remain
available. `readonly :attribute, type: :registered_key` is the readonly shorthand.
Physical scalars name actual model attributes or the supported primary-key alias.
Computed scalars use the separate virtual contract below. Both preserve current
policy grants.

The type's class methods are `scalar :built_in_type`, `version "1"`, and optional
`form_partial`, `index_partial`, `show_partial` relative Rails paths. Built-in
scalars are id/text/textarea/integer/decimal/boolean/date/datetime/enum/select.
Version is a 1..64-character alphanumeric-led string with alphanumeric, underscore,
dot or hyphen characters. Partial paths use lowercase underscore-separated path
segments (digits are also allowed after the leading letter) and are at most
200 characters; absolute/traversal
paths are rejected.

## Hook Signatures

Hooks are public instance methods accepting these calls. Optional parameters or
`**kwargs` may be compatible; required extra arguments are not.

| Call | Required result |
| --- | --- |
| `normalize(value, field:, time_zone:)` | Idempotent scalar of the declared built-in kind |
| `valid?(value, field:, time_zone:)` | Boolean true/false |
| `format(text, field:, time_zone:)` | Valid-encoding plain String, at most 16 KiB |
| `schema(field:)` | Hash of supported scalar schema keywords |

A new instance is constructed for every invocation. The typed scalar/display
String and descriptor are frozen; descriptor options/schema are deeply frozen.
Descriptor attributes are `name`, `type`, `scalar_type`, `options` and
`scalar_json_schema`. There is no record/context/policy parameter. Nil skips
normalize/valid?/custom format; core nullability and nil display still apply.
Temporal values are duplicated before hook freezing, preserving caller objects.

Coercion runs core parsing, normalization, core re-coercion, a second normalization
and equality check, Boolean validation and schema validation of normalized wire
values. Decimal/date/datetime wire values are strings. Ruby coercion also accepts
typed Date for date and Time/TimeWithZone/DateTime for datetime; it returns a fresh
parsed Date or UTC Time at microsecond precision. DateTime is rejected for
date-only fields. Default datetime form/display preserves microseconds. Decimal
coercion rejects Float and nonfinite BigDecimal values. Typed Proposal.values can return directly to execution. Field schemas are combined
with core constraints through `allOf`; nullable wrapping remains core-owned.
Shared schema keywords are type/enum/const/title/description. Wire string schemas
also accept pattern/minLength/maxLength; integer schemas accept minimum/maximum;
Boolean schemas accept neither group. Inapplicable keywords deny configuration.
Decimal uses a string wire schema, so put typed numeric-range checks in valid?.
Enum entries and const must be JSON scalars. String/symbol keyword collisions,
changed core JSON type, references and unsupported keywords deny configuration. Pattern text
is at most 1,000 bytes, title/description each at most 300 bytes and schema JSON
at most 8 KiB. Schemas do not model every accepted raw HTML form string.

Ordinary invalid input, including ArgumentError from normalize/valid?, becomes
generic field errors. Invalid signatures, non-idempotence, mutation, formatter/
schema errors or unexpected hook failure gives `ConfigurationError`.
Hooks run under the Active Record write-prevention guard. This blocks ordinary
Active Record writes, not trusted Ruby I/O or explicit host logging. Purity,
determinism and safe regular expressions remain host responsibilities.

## Partial Locals and Output

| Rendering boundary | Explicit locals |
| --- | --- |
| Form | `field`, `form`, `value`, `input_options` |
| Index/show | `field`, current authorized scalar `value`, formatted `text` |

The framework filters grants before rendering. It supplies no record local;
trusted Rails templates must not reach around this projection to expose other
values. Index rows without a read-grant key skip format/partial invocation;
authorized nil values still render the partial with core nil display text.
Forward input_options to preserve accessibility attributes. Formatter
output loses HTML-safe status and is escaped normally. Templates must preserve
that escaping rather than calling raw/html_safe. This is not a template sandbox.

Built-in select accepts either values (distinct nonempty Strings) or choices
(String label/value pairs), 1..100 values with at most 200 characters each.
Posted integers or display labels are not coerced into a permitted string value.
Blank input is nil only for nullable selects. Readonly excludes writes but does
not turn methods into scalar attributes. Only explicit `virtual` declarations
use the separate computation boundary.

## Computed Scalar Contract

Resource fields may declare `virtual :summary, type: :text, depends_on:
[:name, :points], compute: "CustomerSummary"`. The class inherits
`Fields::Computation`, declares a bounded version string (default "1") and exposes
`call(values, field:, time_zone:)` with a compatible public zero-argument
constructor. The frozen descriptor is the same scalar descriptor as above; the
frozen String-keyed Hash contains only declared dependency snapshots. There is
no record/context/policy parameter. The result goes through the declared core/
plugin scalar coercion, formatting and normal escaping.

A virtual field needs its own current read grant and every recursive dependency's
grant. Missing any graph node hides the field before evaluation. No declassification
or arbitrary model-method access is supplied. Readonly stays true and search/sort
stay false. Create/edit default false but may be true for authorized readonly
form display; they never permit assignment. Widening readonly/search/sort
declarations fail configuration. Virtual fields are forbidden in Operation/Work input schemas.
Graph registration validates declared dependencies/cycles without domain queries:
up to 128 total resource fields, 20 direct dependencies per computed node and eight
virtual levels. One projection cache reuses nodes and physical reads per record;
index titles reuse that projection. Native pages, Selections and collection jobs
share Field.format followed by truncation to 120 characters, including Boolean,
select, datetime and plugin title formatting. A denied virtual title falls back
to Record #id.

Snapshot scalars are nil/Boolean/Integer/String/finite BigDecimal/Date/UTC Time.
Temporal dependencies are copied before freezing; unsupported objects deny.
Each snapshot value, its dependency Hash and each computed scalar are bounded to
16 KiB canonical JSON; computed outputs total at most 64 KiB per projection.
For computed projections, the cooperative one-second budget is checked before/
after every field, including the last physical read, and at values return. It
does not hard-interrupt Ruby/SQL. Ordinary Active Record writes are guarded across
dependency reads, call and coercion. All physical getters, including early-cached
dependencies and physical titles, also use that guard. Trusted Ruby purity and no
extra I/O/lookup remain host responsibilities. Native
failures return a generic unavailable response. Virtual preflight change entries
are excluded; actual current results are recomputed after business execution.

## View Masks and Form Plans

Fields accept Boolean index/show/create/edit/hidden flags. Index/show default true;
hidden defaults false and removes resource read/write/search/sort exposure.
Create/edit permit lifecycle inputs only when the field is writable; for readonly
or virtual fields they can opt into readonly form context under show/read/view
permission. Help text is escaped plain text of 1..500 characters; tab/panel labels
are 1..80 characters each. Layout metadata remains part of Field.contract.

The optional public adapter call is
`presentation_fields(context:, resource:, view:, record: nil)`; Pundit calls its
explicit policy's `presentation_fields(view)`. Missing/nil adds no restriction;
a String/Symbol-name Array intersects ordinary grants. Empty means no fields.
The mask applies before recursive dependency checks; static index/show output
flags apply afterwards. Generic `Access#project(record, view: nil)` does not use
view masks/index/show flags; hidden/read/show/dependency grants still apply.
Generic write fields automatically use create/edit lifecycle masks, including
Runner submission rechecks. Readonly and virtual writes remain denied.

Native generic forms expose writable-only @form_fields/@form_values. @form_plan
is a `Forms::Plan` with immutable Entry(field, editable, value), Panel(label,
entries) and Tab(label, panels) values. Callers supply already-authorized fields/
values and separate readonly_fields/readonly_values; the plan does not authorize
or query records. Write-only fields receive no database prefill; readonly output
needs current show/read/lifecycle-view grants and ignores submitted replacements.
Bounds are 128 entries, eight tabs, 16 panels per tab, 256 KiB per scalar value
and 1 MiB of values per plan. Empty denied groups are omitted. With no JavaScript
all sections remain visible; optional tabs/error navigation do not persist drafts.

## Generic Form Recovery Contract

`Operations::Runner#resume_form(context:, resource:, intent_ref:)` returns a trusted
`Runner::FormSession(intent, record)` for eligible proposed, unbound, unapproved
root UI create/update forms. It requires the original actor/tenant, current
authentication/scope/action/field grants, unchanged resource fingerprint and update
version, and an absolute one-hour created_at window. It renews the same intent's
security version/expiry, with no input/draft, approval, new intent or execution.
Children/selections/custom commands/delete/completed requests are excluded.

Native recovery uses GET /:resource/forms/recover with the UUID only in
X-RailsAiAdmin-Recovery-Intent, no draft payload. Explicit session/ready response
markers bind the Turbo recovery flow; ready is emitted only after successful
form rendering, never for unsuccessful/render-error responses. Ordinary
validation 422 is unchanged.
`config.authentication_path` is nil or a fixed conservative internal host path,
including a relative URL root prefix if needed. The original open DOM alone keeps
input; manual Resume snapshots the current DOM after fresh HTML/binding
validation, transfers only currently editable scalar controls into new CSRF HTML
and requires explicit Save. Disconnect aborts pending recovery. No persistent draft or no-JavaScript
preservation is supplied. See
[Form Session Recovery]({% link _advanced/form-recovery.md %}).

## List Navigation Hints

`Navigation::ListState.new(access, raw, strict: false)` normalizes only q/sort/
direction/page/scope String scalar settings plus a bounded nested filter map
(scope follows the current named-scope grant and omits the granted default;
filters follow current filter grants and field contracts); search rejects invalid encoding and C0/DEL
control characters before database use. Its immutable state is not a URL, saved
query or authority. Native return_to accepts a Hash only and builds a current
resource index path, or dashboard if index is denied. Current search/sort grants
are rechecked; removed options reset page. Direct HTML index syntax/undeclared
sort errors stay 422; revoked eligible options redirect to permitted settings.

`Queries::List#call(..., recover_empty_page: false)` remains strict and does not
recover by default. Native HTML opts in to a single bounded same-scope/filter
count (requested page * 25, maximum 25,000) and clamped requery for empty later
pages, then redirects canonically. Recovery is best-effort under concurrency.
Form recovery carries encoded state through X-RailsAiAdmin-Return-State separately
from the same UUID intent header: ASCII Base64URL UTF-8 JSON, 2,048 encoded bytes/
1,536 decoded bytes maximum. Invalid hints are discarded, never used as URLs.
See [List Navigation]({% link _core_features/list-navigation.md %}) for native
flow retention and the registered template helpers.

## Resource Menu Presentation

`Resource.navigation(group: nil, label: nil, icon: nil, order: 0, hidden: false)`
returns immutable Navigation::Settings; `navigation false` hides only sidebar/
Overview entry points. It changes no direct action/scope/field authority and is
excluded from operation/Selection fingerprints. Group/label/fallback Resource.label
are plain UTF-8 text of 1..80 characters without controls or all-whitespace values.
Order is Integer -1000..1000; hidden Boolean; icon nil or a fixed String name:
users/shopping-bag/life-buoy/document/grid. Unknown keys, Procs, URL targets and
arbitrary SVG/HTML icons are not accepted. Registration rejects a visible
resource whose fallback Resource.label is outside the caption bounds.

`Navigation::Menu.build(context:, resources:, current_key: nil)` authorizes index
before evaluating an entry's metadata, removes hidden entries and groups only
remaining resources. Entry order uses order then registry position; group order
is first appearance in that sorted list, with each group's entries contiguous.
Immutable Group(label, entries)/Entry(key, label, icon, current) snapshots hold no
records/counts/policies. The framework makes no domain/count query; host policies
may query. `resource_navigation` is a request-memoized view helper using the actual
resolved resource key for current marking. Named resource routes preserve mount/
SCRIPT_NAME. Legacy visible_resources still includes all index-authorized entries,
even navigation-hidden ones, for host override compatibility.

The resource_navigation catalog partial takes groups; layout/dashboard contracts
are revisions 3/2. See
[Resource Navigation]({% link _core_features/resource-navigation.md %}).

## Host Custom Controllers and Fixed Statuses

A host controller subclasses `RailsAiAdmin::CustomController` (default layout
false), owns its routes/views/partials/layout and inherits fresh authentication,
CSRF, security headers and action-parameter filtering. Host ApplicationController
concerns are not inherited automatically. Protected admin_context returns fresh
Context; admin_access(key) resolves only a registered resource and grants no
action; callers explicitly authorize/find/project. admin_operation_runner uses the
same shared Runner; admin_routes is the mounted proxy, also a registered view
helper. Protected/view helper admin_csp_nonce returns an immutable copy of the
current prepared response nonce. Custom layouts loading prebuilt Turbo must set
meta[name=csp-nonce] from this helper so its injected progress style passes CSP;
no-JavaScript layouts do not need that Turbo meta. It does not authorize content.
Host route helpers remain host-owned. Optional engine-prefix host routes
use Engine.routes.prepend in an initializer before draw, not late route mutation.
Initial URL redaction outside the engine prefix remains a host responsibility.

Protected `admin_status(kind)` renders a fixed snapshot and does not halt an
action. Use `return admin_status(...)` when selecting a response before business
work. Only these known String/Symbol kinds are supported:

| Kind | HTTP | Code |
| --- | --- | --- |
| authentication_required | 401 | UNAUTHENTICATED |
| forbidden | 403 | FORBIDDEN |
| not_found | 404 | NOT_FOUND |
| conflict | 409 | CONFLICT |
| invalid_query | 422 | INVALID_QUERY |
| invalid_request | 422 | INVALID_REQUEST |
| unavailable | 503 | UNAVAILABLE |
| error | 500 | ERROR |

`Presentation::Status.fetch(kind)` returns immutable kind/http_status/code/title/
message. Exceptions, record values, arbitrary messages and client return URLs
are not status inputs. Explicit host-selected forbidden is 403; default record
AccessDenied mapping still uses anti-enumeration 404 for ordinary unknown/denied
records. HTML/Turbo uses minimal independent status HTML with reload metadata and
no resource navigation/registry lookup. Non-HTML remains plain text, not JSON.
Failed status overrides fall back to fixed plain text with the original HTTP
status/session marker, never a ready recovery marker. Arbitrary action exceptions
and host exceptions_app handling are not replaced. See
[Custom Controllers and Status Pages]({% link _advanced/custom-controllers.md %}).

## Reload and Compatibility

Class names resolve fresh on invocation. A metadata mismatch with an existing
field fails closed until resource definitions reload. Immutable field contracts
include type/version/schema/partial and computation/dependency metadata and
participate in operation, Selection and Work fingerprints. Bump the plugin/computation version for semantic method changes;
method bodies are not hashed. Rebuild definitions and request new forms/Selections
when old contracts invalidate. Association/file/money types and the full release
roadmap remain separate work.
