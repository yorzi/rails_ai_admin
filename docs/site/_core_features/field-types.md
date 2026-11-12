---
layout: default
title: Field Types
nav_order: 5
description: Refine authorized scalar fields with pure normalization, validation and presentation hooks.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* How to register a scalar field type by class name.
* How normalization, validation and schema constraints share an input contract.
* How to customize field partials without widening authorization.
* How version changes affect existing intents and selections.

## Register a Scalar Refinement

A field type refines one built-in scalar. For example, put this host class in
`app/fields/name_type.rb`:

```ruby
class NameType < RailsAiAdmin::Fields::Type
  scalar :text
  version "1"

  def normalize(value, field:, time_zone:)
    value.strip
  end

  def valid?(value, field:, time_zone:)
    !value.empty?
  end

  def schema(field:)
    { minLength: 1, maxLength: 80 }
  end
end
```

Register it in the initializer before resources use it:

```ruby
RailsAiAdmin.configure do |config|
  config.field_types = { trimmed_name: "NameType" }
end
```

Inside an explicitly registered resource whose model has a `name` column:

```ruby
fields do
  id :id
  field :name, type: :trimmed_name, required: true, nullable: false,
    max_length: 120
end
```

Use class-name strings so reload resolves the current host class. Registration
keys must be unique stable lowercase names; they cannot replace built-in types.
The class inherits `Fields::Type`, declares a built-in `scalar` and has a public
zero-argument constructor. No generator is supplied for extension classes.

You can inspect the same coercion contract without submitting a business write:

```ruby
field = RailsAiAdmin.field_registry.build(
  :name, type: :trimmed_name, nullable: false, max_length: 120
)
field.coerce(" Alice ") # => "Alice"
field.format("<Alice>") # => "<Alice>"
```

Formatting returns plain text; Rails escapes it when rendering the page. The
resource declaration and plugin grant no permission. Current read/write/search/
sort grants and operation-input grants still determine whether a field is used.
Physical fields must name actual model attributes, including readonly display.
[Computed Fields]({% link _core_features/computed-fields.md %}) supplies the separate
readonly virtual declaration over currently authorized scalar dependencies.

## Keep Hooks Pure and Stateless

Each hook invocation receives a fresh type instance. Use these public signatures:

| Hook | Input and result |
| --- | --- |
| `normalize(value, field:, time_zone:)` | Frozen typed scalar; return its normalized scalar |
| `valid?(value, field:, time_zone:)` | Frozen normalized scalar; return true, false, or a short message (1–200 characters) shown as the field error |
| `format(text, field:, time_zone:)` | Frozen built-in display text; return a plain String |
| `schema(field:)` | Frozen field descriptor; return a scalar keyword Hash |

`field` is a frozen descriptor with `name`, `type`, `scalar_type`, deeply frozen
`options` and `scalar_json_schema`. It is not a record or policy object. The
`time_zone` keyword is the current caller's zone and is supplied to the three
value hooks. Inherited defaults leave normalization/display unchanged, accept
validity and add no schema constraints. Nil skips the value hooks; field
nullability remains the core contract. Temporal hook inputs are duplicated before
freezing, so a caller's Time is neither frozen nor changed by coercion.

The engine coerces through the built-in scalar, normalizes, coerces again and
checks a second normalization gives the same value. Return a new value rather
than mutating the frozen input; `strip`, rather than `strip!`, fits this example.
A non-idempotent or mutating implementation fails closed. Both built-in limits
and plugin rules apply: trimming cannot rescue raw text already over the core
maximum. `valid?` returning false, or `ArgumentError` from normalize/valid?,
becomes the generic "is invalid"; returning a message string shows that message
instead. Incompatible signatures, formatter/
schema errors or malformed contracts raise `ConfigurationError`. Ordinary
unexpected hook exceptions are converted to a generic configuration error rather
than their original diagnostics.

Schema, normalization, validation and formatting run under Active Record
`while_preventing_writes`. Ordinary Active Record writes are blocked. This is a
guard for trusted Ruby, not a sandbox for raw connections, files, network calls
or explicit logging. Keep hooks deterministic and free of record lookup, I/O,
authority decisions and mutable instance state.

## Narrow the Wire Schema

The schema hook shares `type`, `enum`, `const`, `title` and `description` across
wire scalar types. String schemas also accept `pattern`, `minLength` and
`maxLength`; integer schemas accept `minimum` and `maximum`. Boolean schemas
accept neither group. Inapplicable keywords fail configuration instead of being
silently ignored. String/symbol keys are accepted if they do not collide after
string normalization. Changing the core JSON type is rejected. No references or
nested object/array values are available; `enum` lists JSON scalars and `const`
is a JSON scalar.

The engine intersects constraints with the core schema using `allOf`; a plugin
cannot widen core length/enum/range limits or make a non-nullable field nullable.
Patterns are at most 1,000 bytes, schema title/description at most 300 bytes each,
and the constraints JSON at most 8 KiB. Supported constraints must also form a
valid scalar schema. Required/nullable field options remain independent.

Schemas describe **normalized wire values**, not every form string accepted by
scalar parsing. Integers/booleans use JSON integers/booleans; decimal uses a
string, date uses ISO date text and datetime uses normalized UTC timestamp text.
For decimal numeric ranges, implement `valid?` against the typed BigDecimal;
`minimum`/`maximum` are invalid on its string wire schema. The schema validates
normalized wire values after `valid?`. The public Ruby input path also accepts
typed Date for `date`, and Time/TimeWithZone/DateTime for `datetime`, returning a
fresh parsed Date or UTC Time with microsecond precision. DateTime is rejected
for date-only input. Typed proposal values can be passed back to execution
without a JSON round trip. `InputSchema` uses that same field contract for normal
CRUD and declared operation inputs; this does
not enable provider or Surface integration.

## Customize Only Field Presentation

A type may declare trusted relative Rails partial paths:

```ruby
class NameType
  form_partial "admin_fields/name_input"
  index_partial "admin_fields/name_display"
  show_partial "admin_fields/name_display"
end
```

For `app/views/admin_fields/_name_input.html.erb`:

```erb
<%= form.text_field field.name, value: value,
  maxlength: field.options[:max_length], **input_options %>
```

For `app/views/admin_fields/_name_display.html.erb`:

```erb
<span class="customer-name"><%= text %></span>
```

The explicit form locals are `field`, `form`, `value` and `input_options`. Preserve
`input_options` so invalid/described-by accessibility attributes reach the input.
Index/show locals are `field`, authorized scalar `value` and formatted `text`.
No record is supplied as a local. Display uses the already authorized projection;
a denied field does not become visible through its partial. On an index row, a
missing read-grant key skips both formatter and partial; an authorized key whose
value is nil still renders the partial with the core nil display text.

These are trusted Rails templates with access to ordinary host code, not a view
sandbox. Do not query a record or render extra confidential fields from a partial.
The formatter returns bounded plain String text (at most 16 KiB); the engine strips
HTML-safe status before normal escaping. Keep `<%= text %>` escaping and do not
mark plugin output `html_safe` or render it with `raw`. There is no ViewComponent
adapter in this field API. [Template Overrides]({% link _advanced/template-overrides.md %})
provides a separate cataloged page/layout/partial contract.

## Use String Select Values and Readonly Attributes

Inside a resource's `fields` block, built-in `select` separates labels from wire values:

```ruby
select :status, choices: [["Pending review", "pending"], ["Approved", "approved"]],
  nullable: true
readonly :created_at, type: :datetime
```

Use either `choices:` with label/value string pairs or `values:` with strings,
not both. Values must be distinct, nonempty strings (1 through 100 choices);
integers and submitted labels are rejected. Blank select input becomes nil only
when nullable; otherwise it fails. A stored obsolete value can appear as a disabled
form option, which does not grant permission to submit it. A readonly declaration
still names a real attribute and excludes it from writes, regardless of a host
write grant. It cannot expose an arbitrary method such as `destroy` or a computed
field through a physical declaration. Use the separate computed-field API for
a reviewed readonly derivation.

## Version Changes Deliberately

The field contract includes registration/class metadata, version, scalar, options,
schema and partial paths. Changed field contracts affect operation and Selection
fingerprints. Bump `version` for normalization/validation/presentation semantics
changes; method bodies are not automatically hashed. Reload/rebuild the resource
definitions and reopen old forms or capture a fresh Selection when their contracts
are invalidated. A live field detecting changed class metadata fails closed until
its definitions reload. No migration of old intent evidence is supplied.

## Next Steps

* [Computed Fields]({% link _core_features/computed-fields.md %}) derives readonly values without widening dependency grants.
* [Extension Contracts]({% link _reference/extension-contracts.md %}) lists exact signatures and support limits.
* [Resources and Fields]({% link _core_features/resources-and-fields.md %}) explains separate exposure and query grants.
* [Operations]({% link _core_features/operations.md %}) explains fingerprinted confirmation and replay.
