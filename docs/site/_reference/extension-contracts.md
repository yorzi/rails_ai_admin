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

The current extension surface refines explicit scalar fields. It does not expose
virtual/computed fields, arbitrary record lookup, full-page overrides, an extension
generator or a ViewComponent-specific adapter. Use the runnable
[Field Types]({% link _core_features/field-types.md %}) guide before adding a type.

## Registration and Declaration

`config.field_types` maps stable String/Symbol keys to class-name Strings. Keys
match `[a-z][a-z0-9_]{0,39}`, cannot duplicate after string normalization and cannot
replace a built-in type. The resolved class must be a named subclass of
`RailsAiAdmin::Fields::Type` with a compatible public zero-argument `.new` and
initializer. Resources and operation input blocks use
`field :attribute, type: :registered_key, **options`; built-in DSL methods remain
available. `readonly :attribute, type: :registered_key` is the readonly shorthand.
Every displayed scalar still names an actual model attribute or supported primary
key alias and passes current policy grants.

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
not turn methods into scalar attributes.

## Reload and Compatibility

Class names resolve fresh on invocation. A metadata mismatch with an existing
field fails closed until resource definitions reload. Immutable field contracts
include type/version/schema/partial metadata and participate in operation and
Selection fingerprints. Bump the plugin version for semantic method changes;
method bodies are not hashed. Rebuild definitions and request new forms/Selections
when old contracts invalidate. Association/file/money types and the full release
roadmap remain separate work.
