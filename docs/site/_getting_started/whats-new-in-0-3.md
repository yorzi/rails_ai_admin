---
layout: default
title: What's New in 0.3
nav_order: 6
description: Find and act on records faster with richer filters, reference sorting, saved views, one-step bulk actions, soft delete and child editing from the parent page.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* Which new filters a field can offer.
* How to sort and search a list by a referenced record.
* How people keep their own list settings as saved views.
* How bulk actions work from the list in one step.
* How soft delete and restore work.
* How children are edited from the parent page.
* What to do when you upgrade, and where the Public Preview still has limits.

## Richer Filters

Fields can now offer three more filter operators, each opt-in per field and
behind the same `filter` grant as before:

```ruby
fields do
  email :contact, filterable: %i[contains blank]
  select :state, choices: [ [ "Draft", "draft" ], [ "Approved", "approved" ] ], filterable: %i[eq in]
  date :shipped_on, filterable: %i[gte lte blank]
end
```

`contains` matches part of a text, email or url value. `in` shows a group of
checkboxes for an `enum` or `select` field and matches any ticked choice. `blank`
keeps records with no value or with a value. `filterable: true` keeps its 0.2
defaults. See [Typed Filters]({% link _core_features/typed-filters.md %}).

## Sort and Search by a Reference

A `belongs_to` field can sort and search by the referenced record's title:

```ruby
belongs_to :customer, sortable: true, searchable: :contains
```

Orders now sort by customer name, and searching "ada" finds orders for Ada.
The actor also needs the sort or search grant on the customer's title in the
customer resource, and titles come only from records the actor can see. See
[Associations]({% link _core_features/associations.md %}#sorting-and-searching-by-reference).

## Numbered Pages and Saved Views

Lists that count their records (`count :exact`) show numbered pages, and a list
that fits on one page shows no pagination.

Each person can save the current search, sort, tab and filters as a named view
and open it again from the list. Views are private, and they are checked against
current grants every time they are shown. They need one new table; see
[Saved Views]({% link _core_features/saved-views.md %}).

## Bulk Actions in One Step

The list's bulk bar now offers **Delete selected** and a button for each
collection operation the actor may start. Each one captures the ticked records
and opens that action's review page, so nothing changes until the person
confirms. When a list spans several pages and 100 or fewer records match, **All N
matching records** applies the action to every match. See
[Selections]({% link _core_features/selections.md %}).

## Soft Delete and Restore

Declare a nullable timestamp column, and deleting sets it instead of removing
the row:

```ruby
class ArticleAdmin < RailsAiAdmin::Resource
  model "Article"
  soft_delete :discarded_at
  # ...
end
```

Deleted records leave every admin list, page, search, export and assistant
answer. A **Deleted records** page lets people with the separate `restore`
grant bring one back, with a version check and an audit event. The resource
generator declares `discarded_at` and `deleted_at` columns this way. See
[Soft Delete and Restore]({% link _core_features/soft-delete.md %}).

## Edit Children from the Parent

Child panels on a record page now have an **Edit** link for each child the
person may update. Adding, editing or deleting a child from a panel returns to
the parent page afterwards. See
[Associations]({% link _core_features/associations.md %}#adding-and-editing-a-child-from-its-parent).

## Clearer Doctor Output

`rails_ai_admin:doctor` ends with a summary line, and `ONLY=review` or
`ONLY=errors` hides the other checks. See
[Host Verification]({% link _advanced/host-verification.md %}).

## Upgrading

Copy the saved views migration and run it, then check copied list templates:

```sh
bin/rails generate rails_ai_admin:install --skip
bin/rails db:migrate
```

The [upgrade guide]({% link _reference/upgrading.md %}) lists every step.

## Public Preview Limits

* Ruby 3.3 or newer, Rails 8.1.4.1 or newer below 8.2, and SQLite or PostgreSQL.
* Editing children inside the parent's own form in one save, polymorphic
  references and dedicated attach/detach policies are open.
* Bulk actions take up to 100 records; selecting more than 100 matches is open.
* Chat has a per-person daily message limit. Token and cost budgets and
  automatic conversation retention are open. Live provider behavior and native
  provider APIs still need current verification.
* English ships with the engine. Hosts supply translations for their locales.
  A human screen-reader pass is still open.
* Public Preview contracts may change across 0.x versions. Review template and
  migration changes before updating a host.

See [Development Status]({% link _reference/development-status.md %}) for the
full list, and [What's New in 0.2]({% link _reference/whats-new-in-0-2.md %})
for the setup work of the previous release.

## Next Steps

* [Saved Views]({% link _core_features/saved-views.md %}) - turn the feature on in an existing host.
* [Soft Delete and Restore]({% link _core_features/soft-delete.md %}) - declare a deletion column and the restore grant.
* [Upgrading]({% link _reference/upgrading.md %}) - prepare an existing 0.2 host for 0.3.
