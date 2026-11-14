---
layout: default
title: Typed Filters
nav_order: 10
description: Let granted users narrow a list by exact values, ranges, partial text and empty values on declared scalar fields.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* How to make a field filterable and which operators each type supports.
* Why filters need their own policy grant.
* How filter values are validated, combined and carried in URLs.
* What the index form and template overrides receive.

## Declare Filterable Fields

For a host `Order` model:

```ruby
class OrderAdmin < RailsAiAdmin::Resource
  model "Order"
  key :orders
  title :number
  fields do
    id :id
    text :number, searchable: :prefix, sortable: true
    select :state, choices: [ [ "Draft", "draft" ], [ "Approved", "approved" ] ], filterable: true
    decimal :total, filterable: true
    date :delivery_on, filterable: %i[gte lte]
    boolean :expedited, filterable: true
    email :contact, filterable: %i[contains blank]
  end
end
```

| Scalar type | Allowed operators | `filterable: true` |
| --- | --- | --- |
| `text`, `textarea`, `email`, `url` | `eq`, `contains`, `blank` | `eq` |
| `id`, `enum`, `select`, `boolean`, `belongs_to` | `eq`, `blank` | `eq` |
| `integer`, `decimal`, `date`, `datetime` | `eq`, `gte`, `lte`, `blank` | `gte`, `lte` |

`gte`/`lte` are inclusive. `contains` matches part of the text and ignores case
(SQLite's `LIKE` ignores case for ASCII letters only); `%` and `_` in the value are
literal characters. `blank` keeps records with no value (`"true"`) or with a
value (`"false"`); for text, an empty string also counts as no value.

Pass an Array to choose operators, such as `filterable: %i[eq gte lte]` or
`filterable: %i[contains blank]`. `filterable: true` keeps the defaults in the
last column, so `contains` and `blank` are always an explicit choice. Text
equality is exact and follows your database collation. Virtual and hidden
fields cannot be filtered. A field without `filterable:` keeps exactly its
previous contract.

## Grant Filters Explicitly

A filter reveals values through which records match, even for a column that is
not displayed. Filtering is therefore a separate field grant, denied by default
and never implied by read, search or sort:

```ruby
class AdminPolicyAdapter < RailsAiAdmin::Authorization::Adapter
  def fields(context:, resource:, action:, record: nil)
    case action
    when :read then %i[id number state total delivery_on expedited]
    when :search, :sort then [ :number ]
    when :filter then %i[state delivery_on expedited] + (context.actor.role == "admin" ? [ :total ] : [])
    else []
    end
  end
end
```

With the Pundit adapter, add `filterable_fields` to the resource policy. If your
adapter returns one list for every action, it grants filters as well; switch on
`action` instead.

## Query Semantics

```ruby
RailsAiAdmin::Queries::List.new(context, OrderAdmin).call(
  filters: { "total" => { "gte" => "10.00", "lte" => "100" }, "expedited" => { "eq" => "false" } }
)
```

Conditions are combined with AND, up to 20 in total. Every value is a nonempty
string of at most 200 characters, coerced through the field's own type: `"false"`
is a boolean value, decimals stay exact, dates are ISO dates and datetimes use
the authenticated Context time zone (as `datetime-local` inputs do). A `contains`
value is trimmed and must not be empty; a `blank` value is `"true"` or `"false"`. Values are
bound as parameters on the declared column; no column, operator or SQL comes
from input. An undeclared or ungranted field, an unsupported operator or a value
outside the field's contract raises `AccessDenied` with `INVALID_QUERY`.

Filters apply inside the policy relation and any named scope, then search, sort
and pagination run on the result. OR groups, association paths and saved filters
are not supported yet.

## URLs, Hints and Revocation

The index reads `filter[field][operator]=value` and keeps a canonical nested
`filter` entry in its list hint: blanks are removed and fields/operators follow
the declaration order. A submitted form with blank inputs is redirected once to
that canonical URL. Record, operation, selection and job flows carry the filter
like the other list settings, as nested `return_to[filter][...]` fields.

An undeclared field or operator, or a bad value for a granted field, is an
invalid query (422). A condition whose grant was revoked is dropped with the
"Some list settings are no longer available" notice. Filters are not part of
intent, Selection or receipt identity.

## Templates and Tests

`resource_index` (revision 9) receives `filter_fields`, the currently granted
filterable fields. Each operator renders a labelled input named
`filter[field][operator]`: a text box for `contains` ("Name contains") and an
Any / Empty / Not empty select for `blank` ("Name is"). Keep the hidden list-state fields in both the search
and filter forms (the `list_state_fields` helper does this), and use
`return_navigation_fields` for record forms so nested filters survive.

TestKit field snapshots include a `filter` group, and `assert_field_grants`
requires it:

```ruby
RailsAiAdmin::TestKit.assert_field_grants(context: context, resource: OrderAdmin, expected: {
  read: %i[id number state total delivery_on expedited], write: [], search: [ :number ],
  sort: [ :number ], filter: %i[state delivery_on expedited]
})
```

`rails_ai_admin:doctor` reports filterable columns that appear in no index. That
is a review hint, not a performance verdict.
