---
layout: default
title: "Saved Views"
nav_order: 17
description: "Let each person save a list's search, sort, tab and filters under a name and open it again in one click."
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* How to turn saved views on in an existing host.
* How people save, open, replace and delete a view.
* Why a saved view never grants anything.
* What the list template receives.

## Turn Saved Views On

Saved views need one engine table. New installs get it from the installer. In a
host installed before 0.3.0, copy the new migration and run it:

```sh
bin/rails generate rails_ai_admin:install --skip
bin/rails db:migrate
```

There is no setting to change. Until the table exists, lists show no Saved
views panel and `rails_ai_admin:doctor` reports `saved_views` as closed.

## Save and Open a View

Set up a list the way you use it every day, for example orders in the Drafts
tab, filtered to expedited orders and sorted by delivery date. Open **Saved
views**, type a name such as "Expedited drafts" and choose **Save view**. The
list reloads with the view marked as current.

The next time you open the list, the Saved views panel is open and each view is
a link. A view keeps the search text, sort and direction, list tab and filters.
It never keeps the page number, so a view always opens on page one.

Saving a name you already used replaces that view. Each person keeps up to 20
views per resource; delete one with its **Delete** button to make room. Names
are 1 to 80 characters.

## Views Never Grant Access

A saved view belongs to the person who saved it, in the tenant where they saved
it. Nobody else sees it, and it is not shared through links.

The stored settings are a list hint, the same kind of value the list keeps in
its URL. Each time the list shows a view, it checks the settings against the
person's current grants, exactly as it checks a URL. A sort, search, tab or
filter that the person can no longer use drops out of the link, and the rest
still applies. Records are always read through the current policy relation.

Saving or deleting a view needs index access to the resource and changes no
records, so it writes no audit event.

## Templates

`resource_index` (revision 9) receives `saved_views`: `nil` before the migration
has run, otherwise the person's views in name order. Each view has an `id`, a
`name` and a `state` hash to pass to `resources_path`. Save with
`POST saved_views_path(resource:)` and a `name` parameter, delete with
`DELETE saved_view_path(resource:, id:)`, and include `return_navigation_fields`
in both forms so the current list settings come along.

## Next Steps

* [Typed Filters]({% link _core_features/typed-filters.md %}) - the filters a view can keep.
* [Named Scopes]({% link _core_features/named-scopes.md %}) - list tabs, which a view can also keep.
* [List Navigation]({% link _core_features/list-navigation.md %}) - how list settings are checked and carried between pages.
