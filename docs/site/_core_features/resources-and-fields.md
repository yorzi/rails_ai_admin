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
and field presentation. Money, associations, files and virtual/computed fields
remain unimplemented.

The runtime checks that a scalar projection or title names a model attribute
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

* [Field Types]({% link _core_features/field-types.md %}) adds pure scalar refinements and field partials.
* [Configuration]({% link _getting_started/configuration.md %}) separates field grants from declarations.
* [Operations]({% link _core_features/operations.md %}) describes safe writes and retries.
