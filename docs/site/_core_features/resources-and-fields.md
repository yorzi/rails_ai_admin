---
layout: default
title: Resources and Fields
nav_order: 1
description: Declare scalar exposure and preserve form input semantics.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* How to declare a resource without reflecting every model attribute.
* How readonly and operation-specific fields narrow writes.
* How view masks, readonly context and grouped forms preserve current grants.
* How scalar values are coerced and queried.

## Declare Only Reviewed Fields

```ruby
class CustomerAdmin < RailsAiAdmin::Resource
  model "Customer"
  key :customers
  label "Customers"
  title :name

  fields do
    id :id
    text :name, nullable: false, required: true,
      searchable: :prefix, sortable: true
    textarea :internal_note, readonly: true, max_length: 1000
    integer :points
    decimal :credit
    boolean :active
    date :joined_on
    datetime :reviewed_at
    enum :status, values: %w[pending reviewed]
  end
end
```

Declare columns that exist on your own host model; this example is a field-type
reference, not an instruction to add business columns. No schema inference runs
at boot. The current types are `id`, `text`, `textarea`, `integer`, `decimal`,
`boolean`, `date`, `datetime`, `time`, `enum`, `select`, `email`, `url`, `json`,
`password`, `file`, `files`, `rich_text`, `references` and `belongs_to`. Registered scalar
[Field Types]({% link _core_features/field-types.md %}) can refine coercion, validation
and field presentation. [Computed Fields]({% link _core_features/computed-fields.md %})
adds readonly virtual scalars over explicit currently authorized dependencies.
Money remains unimplemented. `file` fields are covered in
[File Uploads]({% link _core_features/file-uploads.md %}).

### Everyday Types

* `time` is a time of day on a `time` column. Forms use a native time control;
  input is `HH:MM` or `HH:MM:SS` and pages show `14:30`. It can sort, but not
  search or filter.
* `email` is text that must look like an address (`ada@example.com`). Pages show
  it as a `mailto:` link.
* `url` is text that must be an absolute `http` or `https` address. Pages link
  it in a new tab with `rel="noopener noreferrer nofollow"`; a stored value that
  is not http(s), such as `javascript:…`, is shown as text and never linked.
* `json` edits a `json` or `jsonb` column as indented JSON text in a textarea
  and shows it in a scrolling `<pre>` block. Input must parse, nest at most 32
  levels and stay within `max_length` characters (65,536 by default). It cannot
  search, sort or filter, and lists leave it out unless declared `index: true`.
* `password` is write-only, for a `has_secure_password` writer such as
  `password :password`. No read grant can show it: it never appears on a list,
  show page, Chat result or form value, even when a policy's `:read` list names
  it. An empty password box on an edit form keeps the current password; a
  password cannot be cleared. Audit records name the field when it changes,
  and the stored input digest holds only a keyed hash (derived from
  `secret_key_base`) of the new value. Your model's own validations, such as a
  minimum length, still apply. Operation inputs cannot be passwords.
* `rich_text` edits a `has_rich_text` attribute with Trix, loaded from your
  application's Action Text assets (`trix.js` and `trix.css`) only on forms that
  have one. The editor accepts formatted text but refuses file attachments.
  Show pages render the stored HTML through Rails' safe-list sanitizer; lists,
  CSV and Chat get plain text. Input is bounded by `max_length` (1 MB by
  default) and audit names the field when the content changes. It cannot
  search, sort or filter, and lists leave it out unless declared `index: true`.


For physical fields, the runtime checks that a scalar projection or title names
a model attribute
before calling its getter. The single primary-key `id` alias is also supported.
A method such as `destroy` cannot become a display field through a declaration;
a missing attribute raises `ConfigurationError`. Overrides of real attribute
getters remain trusted host Ruby and must be safe to read.

When using Pundit, also declare an explicit `policy "CustomerPolicy"` class name.
The adapter does not infer a policy from the model or reuse an alias policy.
The policy name is optional for a custom adapter that supplies its own decisions.

A resource must declare a string `model`, a unique stable `key`, fields and a
`title` naming a declared field. Keys reserve `assistant`, `audit`, `dashboards`,
`exports`, `imports`, `jobs`, `selections`, `settings`, `doctor`, `assets` and `search`.
`lock_version` is execution metadata and cannot be a resource field. On a model
without `lock_version`, `updated_at` carries the record version, so it may be a
readonly field but never a writable one.

Use [Resource Navigation]({% link _core_features/resource-navigation.md %}) to
group/label/icon/order sidebar and Overview entries. `navigation false` hides only
those menu entries; direct authorization and readonly/write rules stay independent.

## Treat Schema Suggestions as Comments

The resource generator can inspect model schema to suggest supported scalar field
declarations. Suggestions are comments; the generated resource remains readonly,
with only its ID enabled, and is not automatically registered. Sensitive names,
encrypted attributes, foreign keys and polymorphic foreign-type columns, STI
inheritance columns, `lock_version`, authority-like names such as `role`,
`permission` and `security_version`, and unsupported types are excluded. A declared
non-polymorphic `belongs_to` is suggested as a commented `belongs_to` field. No record values are queried to choose suggestions. If the model or
table is unavailable, the safe declaration remains usable for later review.

Suggestions describe types, not permission, privacy or business meaning. Review
each field before enabling it, and supply the separate policy grants. An omitted
suggestion does not prevent an explicit host declaration; doctor can flag
sensitive or unsupported declarations, but it cannot judge their real contents.

## Narrow Write Exposure

```ruby
readonly                  # disable all generic writes
# Or disable individual actions on a writable resource:
disable :destroy
```

Use either pattern in your resource as appropriate. Individual fields accept
`readonly: true`, `create: false` and `edit: false`. `id` defaults to readonly;
primary keys cannot be writable even if the host grants them. Unknown or currently
unwritable submitted fields are rejected rather than silently mass assigned.

`required: true` requires a value in create input: the key must be present and
the value must not be null or blank. It does not replace model validations. Updates are partial: an omitted field keeps
its existing value. The engine retains normal Active Record validations/callbacks.
Validation failures show the host model's own messages for fields the person may
write ("has already been taken", "must be less than 100") and its base messages,
each bounded to 200 characters. Set `config.validation_messages = :generic` to
show "is invalid" instead when model messages could include confidential values.

## Narrow Each View Without Widening Permission

Fields accept Boolean `index`, `show`, `create`, `edit` and `hidden` options.
Index/show default to true; hidden defaults to false. For example, inside a
resource's reviewed `fields` block:

```ruby
text :name, index: false, help_text: "Use the preferred name.",
  tab: "Identity", panel: "Basics"
integer :points, tab: "Account", panel: "Rewards"
boolean :active, readonly: true, create: false, edit: true,
  tab: "Account", panel: "Context"
text :secret, hidden: true
```

`index: false` excludes name from index output and its link title, without
revoking an underlying read grant. `show` controls detail output. `hidden: true`
is a global narrowing of resource read/write/search/sort exposure, even when the
policy grants that field; it is not a hidden HTML input. Ordinary action, scope
and independent field grants still apply.

Create/edit flags control the corresponding generic writable fields. For readonly
physical fields they control optional form display, never writes. A computed
field defaults create/edit to false but can explicitly use true to display
readonly context. Neither readonly nor virtual fields become writable through
these flags or policy grants. Showing readonly context requires current show/read
permission plus the applicable create/edit view permission, including on a new
record. See [Computed Fields]({% link _core_features/computed-fields.md %}).

A host adapter may add a public presentation mask:

```ruby
def presentation_fields(context:, resource:, view:, record: nil)
  return nil unless resource.key == :customers
  view == :index ? [:id, :name] : nil
end
```

An absent method or nil means no additional narrowing; an Array of String/Symbol
names intersects existing grants. An empty Array allows no fields in that view.
Pundit policies can supply public `presentation_fields(view)` with the same
return contract. This is a further restriction, not a substitute for read/write
permission. Exceptions or invalid return types fail configuration. The callback
runs under ordinary Active Record write prevention, not a trusted-Ruby sandbox.

The mask intersects read grants **before** recursive computed-dependency checks.
Exclude a dependency and its computation disappears before the getter/hook runs.
In contrast, static index/show display flags apply after dependency eligibility:
a readable name with index false can still feed an explicitly granted summary
without displaying name itself. Keep every needed dependency in a presentation
mask, even when its static output flag is false.

`Access#project(record, view: :index)` and `view: :show` use those presentation
rules. Generic `view: nil` projection ignores index/show flags and the presentation
callback, while still enforcing show/read grants, hidden and recursive dependency
authorization. It is not the native page projection. Generic Runner writes always
choose their create/edit lifecycle mask and recheck it on submission, so a forged
input or a Ruby write call cannot bypass the mask used by that lifecycle. Custom
operation-input grants remain a separate contract.

## Build Grouped Forms From Authorized Values

`help_text` is plain text of 1..500 characters; `tab` and `panel` labels are plain
text of 1..80 characters. All are optional and escaped normally. The form groups
only currently authorized visible entries, so a removed field cannot leave its
private tab/panel name behind. Unassigned fields use Details when mixed with
tabbed fields. Layout supports 128 entries, eight tab groups and 16 panel groups
per tab, including unnamed fallback groups.

Native generic forms keep `@form_fields` and `@form_values` writable-only.
`@form_plan` contains authorized editable entries and separate readonly outputs
in resource declaration order. Editable prefills come only from the current
readable projection; a write-only field starts blank rather than exposing its
database value. Validation can echo currently permitted submitted scalar text
(such as "08") without persisting a draft. Readonly outputs come from current
read permission and are never replaced by submitted values.

`Forms::Plan` is an immutable scalar presentation snapshot, not an authorization
API or a place to pass records. Trusted callers supply already authorized fields
and value maps. Its entry values are bounded scalar copies; denied/unlisted
values and empty groups are omitted. It supports at most 256 KiB per value and
1 MiB of values across a plan. Existing [template contracts]({% link _reference/template-catalog.md %})
distinguish writable-only assigns from this optional richer layout.

Without JavaScript every section remains visible with ordinary anchor navigation.
With JavaScript, tabs add keyboard Left/Right/Home/End navigation, reveal the
first server-invalid section, reveal native invalid controls and route error-summary
links to their field's section before focusing it. Help/error IDs are connected
through aria-describedby. Preserve those attributes and handlers in overrides.
These controls do not supply persistent session drafts; leaving the page can
still lose unsaved input. [Form Session Recovery]({% link _advanced/form-recovery.md %})
can pause a marked authentication/CSRF failure on an open generic form, then
reauthenticate and manually restore current editable input before explicit Save.
Refreshing or closing the original DOM is outside that preservation boundary.

## Preserve Scalar Meaning

* `false` and `0` remain values rather than becoming missing input.
* Explicit null is accepted only when `nullable` permits it.
* Blank input is empty text, or text that contains only whitespace. A nullable
  field stores blank input as null, so saving an unchanged form never turns a
  null column into `""`. A field declared `required: true` or `nullable: false`
  rejects blank input with "cannot be blank". Text that is not blank is stored
  exactly as typed; it is never trimmed.
* `text` rejects every control character, including tab and line breaks.
  `textarea` accepts tab, line feed and carriage return and rejects the other
  control characters. NUL is never accepted.
* Integer form strings use base ten, including leading zeros.
* Decimal input uses exact `BigDecimal` arithmetic and rejects float input. It
  is never rounded: a value with more fractional digits than the scale, or more
  whole digits than the precision allows, is rejected with a field message.
* Dates use ISO `YYYY-MM-DD`. Forms edit timestamps with a native
  `datetime-local` control in the context's time zone, to the second; saving an
  unchanged form keeps a stored fraction of a second. Pages show
  "30 Oct 2026 01:30 UTC" with the exact value in a `<time>` element, and
  `textarea` values keep their line breaks. Timestamps accept ISO input; absent offsets are interpreted
  in the authenticated context's time zone and normalized to UTC. A day or
  clock time that does not exist, such as `2026-02-30T10:00` or `T24:00`, is
  rejected rather than rolled into the next month.
* Enum values must match the declared string list. Nested hashes and arrays are rejected.

These input rules apply to submitted values. A computed field or an operation
preview returned by host code is checked for its scalar type only.

### Decimal Precision and Scale

A decimal field reads its precision and scale from the resource's column the
first time it coerces or formats a value, never at boot. Declare them to make
the limit part of the reviewed declaration and of the published JSON Schema:

```ruby
decimal :credit, precision: 8, scale: 2
```

Explicit options take precedence over the column. Operation inputs have no
column, so declare the options there when the value is bounded. The resource
generator writes both options from the column. Display and form values are
padded to the scale (`10.50`, not `10.5`) and never rounded.

Text length defaults to 2000 characters. Change `max_length` deliberately for a
text field. Field coercion and supported JSON Schema generation share one schema
implementation; semantic date/time checks happen in Ruby. This schema API alone
does not make a provider or Surface integration available.

## Search and Sort a Bounded Index

A declared `searchable: :prefix` uses prefix search. `:exact` and `:contains` are
also recognized. The search box says which mode applies ("Starts with…",
"Contains…", "Exact match…") and leading and trailing spaces are ignored.
Matching is case-insensitive through `LIKE` on SQLite and `ILIKE` on PostgreSQL;
SQLite folds ASCII letters only, so `ZOË` finds `Zoë` on PostgreSQL but not on
SQLite. A plain B-tree index cannot serve `ILIKE` or contains search; doctor's
`search` line names the fields and the index that can. Search additionally requires a policy `:search` field grant.
Literal `%`, `_` and backslash are escaped rather than treated as user-supplied
SQL patterns. Sort accepts an explicitly granted field and `asc` or `desc`; empty
values sort last in both directions on both databases.

Pages address a record only by its primary key's canonical text: `/orders/01`,
`/orders/1abc` and `/orders/1.5` are not found. A string primary key that
contains a dot or a slash, or equals `new`, cannot be addressed by a page.

The initial index uses pages of 25 records, a stable primary-key tie-breaker and
one extra row to determine whether a next page exists. It normally runs no total
count. Native HTML lists can recover an empty later page with one bounded count/
requery of the same authorized filtered relation and a canonical redirect. The
Ruby query keeps `recover_empty_page: false` by default. Page numbers stop at
1000 and search strings at 200 characters; invalid encoding and C0/DEL control
characters are rejected before database use.
[List Navigation]({% link _core_features/list-navigation.md %}) explains retained
state, current-grant revalidation and the 25,000-row maximum recovery count. Filter AST,
keyset pagination, saved views and association sorting are future work.

## Next Steps

* [List Navigation]({% link _core_features/list-navigation.md %}) retains bounded list context through record flows.
* [Computed Fields]({% link _core_features/computed-fields.md %}) derives readonly values from granted scalar dependencies.
* [Field Types]({% link _core_features/field-types.md %}) adds pure scalar refinements and field partials.
* [Configuration]({% link _getting_started/configuration.md %}) separates field grants from declarations.
* [Operations]({% link _core_features/operations.md %}) describes safe writes and retries.
