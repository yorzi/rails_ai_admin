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
`boolean`, `date`, `datetime`, `enum` and `select`. Registered scalar
[Field Types]({% link _core_features/field-types.md %}) can refine coercion, validation
and field presentation. [Computed Fields]({% link _core_features/computed-fields.md %})
adds readonly virtual scalars over explicit currently authorized dependencies.
Money, associations and files remain unimplemented.

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
`exports`, `imports`, `jobs`, `selections`, `settings`, `doctor` and `assets`.
`lock_version` is execution metadata and cannot be a resource field.

## Treat Schema Suggestions as Comments

The resource generator can inspect model schema to suggest supported scalar field
declarations. Suggestions are comments; the generated resource remains readonly,
with only its ID enabled, and is not automatically registered. Sensitive names,
encrypted attributes, foreign keys and polymorphic foreign-type columns, STI
inheritance columns, `lock_version`, authority-like names such as `role`,
`permission` and `security_version`, and unsupported types are excluded. No record values are queried to choose suggestions. If the model or
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

`required: true` requires presence in create input; it does not replace model
validations or imply `nullable: false`. Updates are partial: an omitted field keeps
its existing value. The engine retains normal Active Record validations/callbacks.
It returns generic errors on permitted fields so arbitrary validator messages do
not expose confidential values.

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
* Empty text remains an empty string. Blank non-text input becomes null when allowed.
* Integer form strings use base ten, including leading zeros.
* Decimal input uses exact `BigDecimal` arithmetic and rejects float input.
* Dates use ISO `YYYY-MM-DD`. Timestamps use ISO input; absent offsets are interpreted
  in the authenticated context's time zone and normalized to UTC.
* Enum values must match the declared string list. Nested hashes and arrays are rejected.

Text length defaults to 2000 characters. Change `max_length` deliberately for a
text field. Field coercion and supported JSON Schema generation share one schema
implementation; semantic date/time checks happen in Ruby. This schema API alone
does not make a provider or Surface integration available.

## Search and Sort a Bounded Index

A declared `searchable: :prefix` uses prefix search. `:exact` and `:contains` are
also recognized. Search additionally requires a policy `:search` field grant.
Literal `%`, `_` and backslash are escaped rather than treated as user-supplied
SQL patterns. Sort accepts an explicitly granted field and `asc` or `desc`.

The initial index uses pages of 25 records, a stable primary-key tie-breaker and
one extra row to determine whether a next page exists. It does not run a total
count. Page numbers stop at 1000 and search strings at 200 characters. Filter AST,
keyset pagination, saved views and association sorting are future work.

## Next Steps

* [Computed Fields]({% link _core_features/computed-fields.md %}) derives readonly values from granted scalar dependencies.
* [Field Types]({% link _core_features/field-types.md %}) adds pure scalar refinements and field partials.
* [Configuration]({% link _getting_started/configuration.md %}) separates field grants from declarations.
* [Operations]({% link _core_features/operations.md %}) describes safe writes and retries.
