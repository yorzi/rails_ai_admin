---
layout: default
title: "Soft Delete and Restore"
nav_order: 18
description: "Keep deleted records in the database, hide them from the admin, and let people with a separate grant restore them."
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* How to make deleting set a timestamp instead of removing the row.
* Where deleted records disappear and where they can be found again.
* How restoring is granted, checked and audited.
* What the doctor and the resource generator do for soft delete.

## Declare a Soft-Delete Column

Give the model a nullable timestamp column, then name it in the resource:

```ruby
class AddDiscardedAtToArticles < ActiveRecord::Migration[8.1]
  def change
    add_column :articles, :discarded_at, :datetime
    add_index :articles, :discarded_at
  end
end
```

```ruby
class ArticleAdmin < RailsAiAdmin::Resource
  model "Article"
  key :articles
  title :title
  soft_delete :discarded_at
  fields do
    id :id
    text :title
  end
end
```

Deleting an article now sets `discarded_at` to the current time. The delete
still goes through the same review page, record version check and audit event
as any other delete, and it is still governed by the `destroy` grant. The model's
`save` callbacks run, its validations do not (a record that no longer validates
can still be deleted), and its destroy callbacks and `dependent:` options do not
run, because nothing is destroyed.

The column cannot also be declared as a field. `rails_ai_admin:resource`
writes `soft_delete` for you when the model has a nullable `discarded_at` or
`deleted_at` timestamp, the columns used by the discard and paranoia gems.

## Where Deleted Records Go

The admin adds `discarded_at IS NULL` to the resource's policy relation, so a
deleted record leaves everything that reads through it: lists and counts, record
pages, global search, CSV export, selections and bulk actions, child panels,
reference pickers and labels, and the assistant's tools. Bulk delete soft-deletes
each selected record in the same way.

Your own application code is not affected. If the rest of the app should also
ignore deleted rows, scope them out in the model, for example with the discard
gem's `kept` scope in your policy.

## Restore a Record

People who may restore see a **Deleted records** link on the list. That page
shows the resource's deleted records, newest first, inside the same policy scope,
with a **Restore** button on each row the person may restore. Restoring clears
the column, takes the person to the record, and records a `restore` event in the
audit log.

Restoring is its own grant. A custom adapter receives `action: :restore`, with
the record for each row and without one for the page itself. With Pundit, add
`restore?` to the resource policy:

```ruby
class ArticlePolicy < ApplicationPolicy
  def destroy? = user.admin?
  def restore? = user.admin?
end
```

The full-access preset allows it. `disable :restore` turns it off for a
resource, and a `readonly` resource never restores.

A restore is checked the same way as an edit. The record must still be deleted
and inside the policy scope, the person's grant is checked against that record,
and the version shown on the page must match, so a record changed in between
asks the person to look again. The restored record must land back inside the
policy relation, or nothing changes.

## Doctor

`rails_ai_admin:doctor` reports `soft_delete:<resource>` as an error when the
column is missing or not a nullable timestamp, and otherwise as a review item
that says whether the column has an index. Lists filter on it on every page, so
add one for large tables.

## Next Steps

* [Selections]({% link _core_features/selections.md %}) - bulk delete, which soft-deletes each record.
* [Pundit and Devise]({% link _advanced/pundit-and-devise.md %}) - where `restore?` lives.
* [Record History]({% link _core_features/record-history.md %}) - the audit log that records deletes and restores.
