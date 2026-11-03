---
layout: default
title: Associations
nav_order: 12
description: Show, choose and filter belongs_to references, and list a record's children, through each target resource's own grants.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* How to declare a `belongs_to` field and what it stores.
* How references are labelled, linked and loaded without per-row queries.
* Which targets a form offers and a write accepts.
* How to list a parent's children with `has_many`.
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
primary key. If the actor cannot list the target resource, or more than 100
targets exist, the form shows a plain text input for the target's key instead.
Association search is planned (see below).

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
grant. The filter form renders the same bounded picker, or a key input past 100
targets. The value narrows the already-authorized list; it never widens it.

```text
/admin/orders?filter[customer][eq]=42
```

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
  rows it shows.

The panel adds no write path. Creating, attaching or detaching children happens
in the child resource's own forms and operations.

## Templates

Two catalogued partials are overridable with `rails_ai_admin:override`:

| Key | Locals |
|---|---|
| `field_reference` | `field`, `value`, `reference` (`id`, `label`, `resource_key`, `visible`; nil for a blank value) |
| `resource_associations` | `panels` (each with `name`, `label`, `resource_key`, `rows`, `more`, `list_filter`) |

`resource_show` (revision 3) adds `association_panels`, and `field_form`
(revision 2) renders the reference picker. Overrides must keep links and labels
from the supplied references; looking records up directly would bypass the
target grants.

## Not Supported Yet

* Association search, sort and label columns (LIST-019): `belongs_to` fields
  cannot be `searchable` or `sortable`.
* A searchable picker endpoint for more than 100 targets.
* Polymorphic, `has_one`, `has_many :through` and many-to-many writes.
* Nested child forms, attach/detach/reparent policies and the dependent-destroy
  preview required by CRUD-021.
