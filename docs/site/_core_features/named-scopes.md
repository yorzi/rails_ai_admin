---
layout: default
title: Named Scopes
nav_order: 9
description: Offer granted list tabs that can only narrow the current authorized relation.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* How to declare named list scopes and an optional default.
* Why each scope needs its own policy grant.
* How a scope body is intersected with the policy relation.
* How scopes travel through list hints and template overrides.

## Declare Scopes on a Resource

For a host `Order` model with `state` and `expedited` columns:

```ruby
class OrderAdmin < RailsAiAdmin::Resource
  model "Order"
  key :orders
  title :number
  fields do
    id :id
    text :number, searchable: :prefix, sortable: true
  end
  scopes do
    scope :drafts, -> { where(state: "draft") }, label: "Drafts", default: true
    scope :reviewed, -> { where(state: %w[approved rejected]) }
    scope :expedited, -> { where(expedited: true) }
    scope :all, label: "All orders"
  end
end
```

The declaration is `scope(name, body = nil, label: nil, default: false)`. Names
are lowercase identifiers of at most 40 characters. A label is plain text of 1..80
characters and defaults to the humanized name. A body is a zero-argument lambda;
no body means the whole authorized relation. At most one scope is the default and
a resource declares at most 20. Declaring a scope does not run its body.

A body may use model scopes, `where` and `joins`. It must not use `limit`,
`offset`, `select`, `group`, `having`, `from`, `includes`, `preload` or
`eager_load`; those fail with `ConfigurationError` when the scope is used. Bodies
run with Active Record writes prevented, and any exception becomes a generic
configuration error. Named scopes need a single-column primary key.

## Grant Scopes Explicitly

A scope predicate can tell a user something about fields they cannot read. A
"missing internal note" tab reveals which notes are empty even when the note
itself is hidden. Scopes are therefore granted separately and denied by default:

```ruby
class AdminPolicyAdapter < RailsAiAdmin::Authorization::Adapter
  def named_scopes(context:, resource:)
    return [] unless resource.key == :orders
    %i[drafts reviewed all] + (context.actor.role == "admin" ? [ :expedited ] : [])
  end
end
```

With the Pundit adapter, define `permitted_named_scopes` on the resource policy:

```ruby
class TicketPolicy
  def permitted_named_scopes
    context.actor.role == "viewer" ? %i[open triaged] : %i[open triaged missing_note]
  end
end
```

Unknown granted names are ignored. The UI shows declared scopes that are
currently granted, in declaration order. The framework cannot check which columns
a trusted body reads, so grant a scope only to users allowed to learn its
predicate.

## Scopes Only Narrow

The framework does not merge the body into the policy relation. It runs the body
on its own and keeps only the primary keys that the policy relation also returns:

```ruby
policy_relation.where(id: candidate.unscope(:order).select(:id))
```

A body that calls `unscoped`, adds `or`, or names another tenant still cannot
widen the list, and joins cannot duplicate rows. Search, sort, pagination and
empty-page recovery all run on the scoped relation. The policy scope is still the
authority; a scope is a narrower view of it.

## Defaults, URLs and Revocation

Without a `scope` parameter, the index applies the declared default **if it is
currently granted**. Otherwise it shows the whole authorized relation. The
granted default is omitted from URLs, so `/admin/orders` and
`/admin/orders?scope=drafts` give the same canonical list. Tabs keep search and
sort and reset the page.

`scope` is the fifth list-hint key alongside `q`, `sort`, `direction` and `page`,
and travels through record, operation, selection and job flows like the others.
An undeclared or malformed name is an invalid query (422). A declared scope whose
grant was revoked is dropped with the "Some list settings are no longer available"
notice. Scopes are not part of intent, Selection or receipt identity.

Trusted code can use the strict query API directly:

```ruby
page = RailsAiAdmin::Queries::List.new(context, OrderAdmin).call(scope: "reviewed")
page.scope # => "reviewed"
```

`call(scope: nil)` applies the granted default. An ungranted or unknown name
raises `AccessDenied` with `INVALID_QUERY`; the query API never falls back.

## Templates and Tests

The `resource_index` template (revision 3) receives `list_scopes` (current
granted definitions) and `current_scope` (the applied name, or nil). An override
should keep the labelled `nav.raa-scopes` links, `aria-current="true"` on the
applied scope, and the hidden `scope` field in the search form.

TestKit snapshots current grants:

```ruby
RailsAiAdmin::TestKit.assert_named_scopes(context: context, resource: OrderAdmin,
  expected: %w[drafts reviewed all])
```

Scopes do not add record counts, saved views or typed filters. Those remain
planned work; see the development status.
