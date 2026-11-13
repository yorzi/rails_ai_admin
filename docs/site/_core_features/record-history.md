---
layout: default
title: Record History
nav_order: 13
description: Show who changed a record, when and which fields, from the audit the Runner already keeps.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* How to turn on a record's History page.
* What the page shows and what it leaves out.
* How to show people's names instead of actor references.

## Turn It On

Every write through the shared Operation Runner already records an audit event:
who, when, which operation, which fields changed and whether it was saved. A
History link on a record's page lists those events, newest first, once your
policy grants it. With a custom adapter:

```ruby
def view_history?(context:, resource:, record:)
  context.actor.admin?
end
```

With the Pundit adapter, add `view_history?` to the resource's policy:

```ruby
def view_history? = user.actor.admin?
```

The grant is default-deny and independent of the other grants. The actor also
needs the record's ordinary `show` grant, and the record must be inside the
policy scope. The page is `<admin>/<resource>/<id>/history`.

## What the Page Shows

Each row has the time, the change (Created, Updated, Deleted or a custom
operation's description), the changed fields and who made it. A change that was
not saved, such as an edit that lost to a newer one, shows "Not saved" with its
outcome code. A change proposed or reviewed in Chat names its origin.

Field names appear only for fields the actor may currently read or write; the
others are counted ("1 other field"), so the page never reveals a field your
policy hides. Values are never stored in the audit, so the page cannot show
before-and-after values. A password change shows only the field's label.

The page lists 50 changes at a time, with a link to older ones. It reads only
the current tenant's events for that resource and record. History is kept for
records that still exist; a deleted record has no page.

Run `bin/rails db:migrate` after upgrading: the
`add_record_index_to_rails_ai_admin_audit_events` engine migration adds the
index this page reads.

## The Audit Log

A separate default-deny grant, `view_audit_log?(context:, resource:)` (Pundit:
`view_audit_log?` on the resource's policy), adds **Audit log** to the menu. It
lists the current tenant's events for every resource that grants it, newest
first, 50 at a time, including CSV exports and rejected writes. Filter by
resource, change, outcome or actor (click a name). Field names follow each
resource's current read and write grants, as on the History page; a record link
opens the record's page, which applies its own scope and show grant again.

## Show Names Instead of References

Audit events store an actor reference such as `raa:actor:User:42`, which the page
shows as "User #42". To show names, add `actor_labels` to your context adapter.
It receives the references on the page and returns a Hash of display names:

```ruby
class AdminContext
  def resolve(controller)
    # ...
  end

  def actor_labels(context:, actor_refs:)
    ids = actor_refs.filter_map { |ref| ref.delete_prefix("raa:actor:User:") if ref.start_with?("raa:actor:User:") }
    User.where(id: ids).to_h { |user| [ "raa:actor:User:#{user.id}", user.name ] }
  end
end
```

Scope that lookup to what the current admin may see; a missing or invalid name
falls back to the reference text.
