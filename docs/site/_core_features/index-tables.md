---
layout: default
title: Index Tables
nav_order: 11
description: Choose index columns, a default order, the page size and an optional bounded match count.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* How to declare index columns, a default sort, page size and counting.
* How these settings interact with read and sort grants.
* Why exact counts are bounded and estimates are not offered.
* What changed in the index template.

## Declare Index Settings

```ruby
class OrderAdmin < RailsAiAdmin::Resource
  model "Order"
  key :orders
  title :number
  fields do
    id :id
    text :number, searchable: :prefix, sortable: true
    decimal :total
    date :delivery_on, sortable: true
    textarea :review_note, index: false
  end
  index do
    columns :number, :total, :delivery_on
    default_sort :delivery_on, :desc
    page_size 20
    count :exact
  end
end
```

| Option | Values | Default |
| --- | --- | --- |
| `columns` | 1..50 distinct declared fields visible on index | every index-visible field, in declaration order |
| `default_sort` | a declared sortable, non-virtual field and `:asc`/`:desc` | primary key ascending |
| `page_size` | 1..100 | 25 |
| `count` | `:none` or `:exact` | `:none` |

Each option may appear once. Registration rejects unknown options, hidden or
index-hidden columns and a default sort on a field that is not declared sortable.
Without an `index` block the list behaves exactly as before. These settings are
presentation only and do not affect operation approvals or Selections.

## Grants Still Decide

Columns choose the order and subset of fields the actor may already read on the
index. A listed column without a current read grant is omitted, and so is a
computed column whose dependency the index presentation mask hides. Only the
listed columns and the record title are computed for each row.

The default sort applies only while the actor holds the sort grant for that field;
otherwise the list falls back to primary-key order, because sorting by a field
reveals its relative values. The primary key always breaks ties. The default
order is implicit in URLs and list hints, and header `aria-sort` shows it.

## Counting

`count :exact` shows "N matching records" for the current authorized, scoped,
filtered and searched list. The count stops at 10,000 and then reads "More than
10,000 matching records", so a large table never runs an unbounded `COUNT(*)`.
Database table statistics are not used for estimates: they cover every tenant
and ignore filters, so they would disclose data and mislead.

`Queries::List` exposes the same information on its `Page`: `sort`, `direction`,
`page_size`, `count` and `count_capped`.

## Layout and Templates

Table cells no longer break inside words, and short machine values (ids, numbers,
dates, booleans) stay on one line. A wide table scrolls inside its labelled,
focusable region, which keyboard arrow keys can scroll.

`resource_index` is now revision 5. An override should read the applied order
from `@page.sort`/`@page.direction` rather than the raw URL, render
`@page.count` when present, and iterate `@columns`, which is already ordered and
authorized.
