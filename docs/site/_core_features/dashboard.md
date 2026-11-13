---
layout: default
title: Dashboard and Search
nav_order: 16
description: Show counts, metrics and daily trends on the overview, and search every resource from one box, through the list grants.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* Which counts the overview shows without any declaration.
* How to declare dashboard metrics and trend charts.
* How the header search chooses resources and records.

## Search Everything

When the actor may list and search at least one menu resource, the header shows
a search box. It opens `<admin>/search?q=…`, which runs each such resource's own
list search (its policy relation, default list tab and granted search fields)
and shows up to five records per resource, each through its own show grant, with
a link to the full list for that search. Resources hidden from the menu are left
out, and one search queries at most 30 resources. `search` is a reserved
resource key.

## Counts on Resource Cards

The overview page shows a record count on a resource's card when its list
already opts into exact counts (`index { count :exact }`). The count uses the
same policy relation, default list tab and 10,000 bound as the list, so a larger
table reads "More than 10,000 records". Other resources show no count and cost
no query.

## Metrics and Trends

A resource can add widgets to the overview:

```ruby
class OrderAdmin < RailsAiAdmin::Resource
  # ...
  scopes do
    scope :drafts, -> { where(state: "draft") }
  end
  dashboard do
    metric :all                                  # every record in the policy scope
    metric :drafts, scope: :drafts, label: "Draft orders"
    trend :created_at, days: 30, label: "New orders"
  end
end
```

* `metric` counts the policy relation, narrowed by a declared list tab when
  `scope:` names one. The card links to that list. A metric whose tab the actor
  is not granted (`named_scopes`) is left out. Counts stop at 10,000.
* `trend` charts records per day for the last 7 to 90 days over a declared
  `date` or `datetime` field, in the context's time zone. It needs the field's
  read grant and reads at most 50,000 values. The chart is an inline SVG
  (no script, CSP-safe); its caption gives the total and **Show the numbers**
  opens a table of every day for assistive technology.

A resource declares at most eight widgets. Widgets appear for menu resources
the actor may list; nothing is cached between requests.

