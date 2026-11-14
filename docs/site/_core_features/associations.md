---
layout: default
title: Associations
nav_order: 12
description: Show, choose, filter, sort and search belongs_to references, edit many-to-many lists, and show a record's children, through each target resource's own grants.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* How to declare a `belongs_to` field and what it stores.
* How references are labelled, linked and loaded without per-row queries.
* Which targets a form offers and a write accepts.
* How to sort and search a list by the referenced record's title.
* How to list a parent's children with `has_many` and `has_one`.
* How to edit a many-to-many list with `references`.
* What is not supported yet.

## Declare a Reference

For a host `Order` model with `belongs_to :customer`:

```ruby
class OrderAdmin < RailsAiAdmin::Resource
  model "Order"
  key :orders
  title :number
  fields do
    id :id
    text :number, required: true, nullable: false
    belongs_to :customer, filterable: true
  end
end
```

`belongs_to :customer` declares a field named `customer` that reads and writes
the `customer_id` column. Its value is the target's primary key as text, such as
`"42"` or a UUID. It is never a record. The defaults follow Rails:

| Option | Default | Meaning |
|---|---|---|
| `resource:` | `:customers` (the pluralized name) | Registry key of the target resource |
| `foreign_key:` | `"customer_id"` | The column on this model |

Both must be stable names. The target resource must be registered, or the
registry fails at boot. On first use, and in `rails_ai_admin:doctor`, the
declaration must also match a non-polymorphic `belongs_to` reflection on the
model whose foreign key is that column and whose primary key is the target's
single primary key. A mismatch is a configuration error, not a silent write to
the wrong column.

Grant the field like any other: policies list `:customer` (Pundit:
`readable_fields`, `writable_fields`, `filterable_fields`). Use the field name,
not the column.

## Labels and Links

Index, show and readonly form views show the target's
[title]({% link _core_features/resources-and-fields.md %}) through the **target**
resource's own policy relation, show grant and title read grant. When the target
is visible, the label links to its show page. Otherwise the view shows a
placeholder built from the already-readable key, such as `Customer #42`, without
a link. A target that is missing, in another tenant or not shown to this actor
renders the same placeholder, so a page never reveals which case applies.

An index page loads every reference in a column with one query against the
target relation, not one query per row. Host target policies run per resolved
target and should avoid their own per-record queries.

## Choosing a Target

New and edit forms render a select of up to 100 targets the actor can currently
list and see, ordered by the target title when its sort is granted and then by
primary key. Past 100 targets the form shows a text input for the target's key
with a search box under it. The search box asks
`GET /admin/customers/references/search?q=…`, which answers with exactly what
the target's own list would show this actor for that text: its policy
relation, its granted search fields and a show grant per record, at most 20
results, plus an exact match on a typed key. Choosing a result fills the key.
The search box has no name and is never submitted; without JavaScript, or for
a target with no granted search fields, the key input still works alone. If the
actor cannot list the target resource, the form shows only the key input.

Every write rechecks the submitted key in the shared Runner, inside the same
transaction as the domain write:

* A **changed** reference must name a target in the target resource's current
  relation with a show grant. Otherwise validation fails with
  `is not an available choice`, the same message for missing, foreign and hidden
  targets.
* An **unchanged** stored reference is accepted even if the actor can no longer
  see it, so saving other fields never forces clearing it. The form keeps it
  selected as `Customer #42 (not available)`.
* A blank value clears a nullable reference. Use `nullable: false` (and the Rails
  `belongs_to` presence validation) to require one.

If a target disappears after that check and a database foreign key rejects the
write, the whole transaction rolls back and the result is `CONFLICT`. Add a
foreign-key constraint to make that race visible.

The field's write grant is the reparenting authority: granting `:customer` lets
an actor move an order to another visible customer. A separate attach/detach
policy is not implemented.

## Filtering by Reference

`filterable: true` offers `eq` only, behind the usual independent `:filter`
grant. The filter form renders the same bounded picker, or past 100 targets the
same key input and search box. The value narrows the already-authorized list; it never widens it.

```text
/admin/orders?filter[customer][eq]=42
```

`filterable: %i[eq blank]` adds an Any / Empty / Not empty choice for orders
with or without a customer.

## Sorting and Searching by Reference

A `belongs_to` field can sort and search by the target's title:

```ruby
belongs_to :customer, sortable: true, searchable: :contains
```

Sorting by Customer orders the list by each customer's name, and searching
"ada" finds orders whose customer's name contains "ada". `searchable:` takes the
same `:prefix`, `:contains` and `:exact` modes as other fields, applied to the
target title.

The title belongs to another resource, so both resources must agree:

* The actor needs the `:sort` or `:search` grant on the `belongs_to` field here.
* The actor must be allowed to list the target resource and hold the same grant
  on its title there. With `CustomerAdmin` titled `name`, sorting orders by
  customer needs `:sort` on `CustomerAdmin`'s `name`.
* The target title must be a stored column, not a virtual field or another
  reference.

Without those grants the column header is not a link and the field is left out
of search. Titles come from the target's own policy relation: an order whose
customer the actor cannot see sorts like an order without a customer (last in
both directions), and searching never matches it. Sorting adds one left join to
a subquery of that relation, and searching one `IN` subquery, so index the
target title column for large tables.

## Child Lists with has_many

Declare a readonly child panel on the parent's show page:

```ruby
class CustomerAdmin < RailsAiAdmin::Resource
  model "Customer"
  key :customers
  title :name
  fields do
    id :id
    text :name
  end
  has_many :orders, limit: 5
end
```

`has_many :orders` lists records of the registered `orders` resource whose
`belongs_to` field `customer` (the parent model's underscored name) points at
this record. Use `resource:` and `via:` when the names differ, and `label:` for
the heading. `limit:` is 1..50 (default 10). A resource declares at most 10
panels.

The panel reads children only through the child resource:

* It appears only with the child `index` grant and a read grant on the child's
  reference field. Listing children by parent would otherwise reveal that value.
* Rows come from the child policy relation, ordered by primary key, and link
  only where the child show grant allows.
* A **View all** link opens the child list filtered by this parent only while
  the child reference field has a filter grant. Otherwise the panel says how many
  rows it shows. Like the panel, the link lists every child: when the child has a
  granted default list tab, the link carries `scope=_none` so the default tab does
  not hide children the panel showed. See [Named Scopes]({% link _core_features/named-scopes.md %}).

The panel adds no write path. Creating, attaching or detaching children happens
in the child resource's own forms and operations.

## Adding and Editing a Child from Its Parent

When the actor may create a child and write its reference back to the parent, a
`has_many` panel shows **Add invoice** (and a `has_one` panel shows **Add
profile** while it is empty). The link opens the child's ordinary new form with
`prefill[customer]=<parent key>`, so the reference is already chosen. The form
is the child's own: its policy, field grants and validations apply, and nothing
is written until the person saves.

A new form takes `prefill[...]` only for writable `belongs_to` fields and only a
target the actor can currently see; anything else is ignored. Use it in your own
links too, for example from a custom page.

Each child the actor may update also gets an **Edit** link in the panel. Forms
opened from a panel carry `back[resource]` and `back[id]`, so saving, deleting
or cancelling returns to the parent page instead of the child's list. Like
`return_to`, it is only a hint: it names a registered resource and a canonical
key, and when the actor can no longer see that parent the form returns to its
usual page. Add `back` to your own links in the same way.

## A Single Child with has_one

For a model `has_one`, declare a panel the same way; it shows the one child or
"No records.":

```ruby
class UserAdmin < RailsAiAdmin::Resource
  # ...
  has_one :profile, resource: :profiles, via: :user
end
```

`resource` defaults to the pluralized name and `via` to the parent model's
name, as for `has_many`. The same grants apply: the child resource's index
grant, a readable `belongs_to` back to the parent, and the child's own show
grant for the link.

## Many-to-Many Lists with references

A `references` field edits a `has_many` (including `:through`) or
`has_and_belongs_to_many` association through the model's `<singular>_ids`
writer:

```ruby
class Article < ApplicationRecord
  has_many :taggings
  has_many :tags, through: :taggings
end

class ArticleAdmin < RailsAiAdmin::Resource
  # ...
  fields do
    references :tags                      # resource: :tags, foreign_key: "tag_ids"
  end
end
```

`resource` names the target resource (default: the field name) and
`foreign_key` the ids writer (default: `<singular>_ids`). The target must be
registered. Grant the field in `:read` and `:write` like any field.

* The value is the sorted list of target keys, at most 100. Show pages label
  each through the target's own relation and show grant, linking only the ones
  the actor may open; others read "Tag #5". Lists leave the field out by
  default (`index: false`), because reading keys costs a query per row; CSV
  export preloads them.
* Forms show a checkbox per visible target when there are at most 100. With
  more, the current targets stay as checkboxes and a key input with the search
  picker adds one more per save.
* A write may add only targets the actor can currently see in the target
  resource. Stored targets the actor cannot see are always kept, so a person can
  neither remove nor learn about records the target policy hides.
* Join rows change no column of the owner, so a changed list touches the record:
  its version advances, a concurrent form conflicts, and the audit names the
  field. An unchanged list writes nothing.
* A `references` field cannot search, sort or filter, and operation inputs
  cannot be lists.

## Templates

Two catalogued partials are overridable with `rails_ai_admin:override`:

| Key | Locals |
|---|---|
| `field_reference` | `field`, `value`, `reference` (`id`, `label`, `resource_key`, `visible`; nil for a blank value) |
| `resource_associations` | `panels` (each with `name`, `label`, `resource_key`, `rows`, `more`, `list_filter`, `back`; each row has `id`, `label`, `linked`, `editable`) |

`resource_show` (revision 3) adds `association_panels`, and `field_form`
(revision 2) renders the reference picker. Overrides must keep links and labels
from the supplied references; looking records up directly would bypass the
target grants.

## Not Supported Yet

* Sorting or searching by a reference's other columns, or across more than one
  reference (`order.customer.account.name`).
* Polymorphic associations, and editing a `has_one` child from its parent.
* Editing children inside the parent's form in one save (nested forms); use
  the panel's Add and Edit links, attach/detach/reparent policies and the dependent-destroy
  preview required by CRUD-021.
