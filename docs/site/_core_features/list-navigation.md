---
layout: default
title: List Navigation
nav_order: 7
description: Carry bounded search, sort and page hints through native admin flows without granting redirect or record authority.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* How native links retain normalized list state across record and operation flows.
* How current query grants and empty-page recovery affect a return path.
* How recovery headers carry Unicode state without adding a query to form actions.
* Which navigation helpers an overridden template must preserve.

## Carry a List Hint Rather Than a URL

The native index uses `q`, `sort`, `direction`, `page` and, when configured,
`scope` ([Named Scopes]({% link _core_features/named-scopes.md %})) and a nested
`filter` map ([Typed Filters]({% link _core_features/typed-filters.md %})). Links/forms for a
record flow carry those same settings in a nested `return_to` Hash. It never
accepts a destination URL, host, resource name, controller or arbitrary route.
Every return link is generated for the **current resource index**, or the admin
dashboard if current index permission is denied. The registered resource key/alias
stays bound to the current controller resource, even when another resource uses
the same model.

Trusted host code can inspect the same normalization with an authenticated
`context` and registered `CustomerAdmin` whose name field permits search/sort:

```ruby
access = RailsAiAdmin::Authorization::Access.new(context, CustomerAdmin)
hint = RailsAiAdmin::Navigation::ListState.new(
  access, { "q" => "客户 🚀", "sort" => "name", "direction" => "desc", "page" => "2" }
)
state = hint.state
```

`ListState` is an immutable plain hint with `state`, `index_allowed?` and
`discarded?`. Its String values are copied/frozen. It is not permission to read a
record, a saved query, an approval, a record identifier or an alternate operation
binding. Changing navigation does not change a business intent's replay identity.

Only these values are accepted in `return_to`:

| Key | Shape |
| --- | --- |
| `q` | Valid text String, at most 200 characters, with no C0/DEL control characters |
| `sort` | Lowercase field-name String, at most 80 characters, currently eligible for sort |
| `direction` | String `asc` or `desc`, meaningful only with sort |
| `page` | Decimal String from `1` through `1000`, without leading zeros |

Nil/blank values are omitted. Ascending direction and first page are canonical
implicit defaults, so the normalized state omits `direction: asc` and `page: 1`.
Invalid text encoding and control characters are rejected before database use.
Nested values, numeric/Boolean values, unknown keys and URL strings are not a
return-state contract. A malformed return hint is discarded with a native notice;
it cannot become a route or escape the engine. The public List query API has its
own typed arguments and remains strict.

## Recheck Search and Sort Authority

Every request rechecks current index/search/sort/scope/filter grants. A removed search setting
or sort grant is dropped, and discarded settings reset page to its default.
Unchanged permitted settings survive. If index itself is denied, a member page
can still be authorized independently, but its return link goes to Administration
rather than granting list access.

The native index distinguishes malformed requests from revoked settings:

| Native HTML index request | Behavior |
| --- | --- |
| Invalid scalar syntax, direction or page | HTTP 422 |
| Undeclared, hidden, virtual or non-sortable field named as sort | HTTP 422 |
| Declared eligible physical sort whose current grant is gone | HTTP 303 to normalized permitted settings with notice |
| Search is no longer available under current grants | Drop search/reset page and HTTP 303 with notice |

`Queries::List` itself still rejects unavailable search/sort with `INVALID_QUERY`;
HTML normalization does not make that Ruby API silently permissive. Sort headers
are offered only for currently displayed readable columns that also have a sort
grant. Clicking a header toggles direction and resets page. Search preserves sort/
direction and resets page. Pagination carries canonical settings; the link to
page one drops its page parameter. With `count :exact`, the list shows numbered
pages (the first, the last and two either side of the current page, marked with
`aria-current="page"`); otherwise it shows Previous and Next around the page
number. A list that fits on one page shows no pagination. No link goes beyond
page 1000.

## Recover an Empty HTML Page Once

Lists normally fetch 25 rows plus one to detect a next page, with a stable primary
key tie-breaker and no total count. If a deletion or permission/filter change
empties a requested HTML page above one, the native index enables bounded recovery.
It counts only the current authorized, filtered relation, bounded to requested
page times 25 (at most 25,000), clamps the page and performs one bounded requery.
This limits matching rows counted, not physical rows an unindexed database filter
may need to inspect.
The controller redirects with HTTP 303 to the canonical recovered page and a
notice. First-page empty results remain an ordinary empty list.

Trusted callers opt into that same query behavior explicitly:

```ruby
page = RailsAiAdmin::Queries::List.new(context, CustomerAdmin).call(
  search: "Alice", sort: "name", page: "2", recover_empty_page: true
)
```

`recover_empty_page` defaults to false. `Page#number` reports the recovered page;
the Ruby query does not perform an HTTP redirect. The count/requery uses the same
scope and filter rather than counting another tenant's records. This is
best-effort handling of concurrent changes, not a consistent snapshot or an
unbounded retry loop. A later change can still empty a newly reached page.

## Retain Context Across Native Flows

Show, new/edit, validation/stale forms, delete confirmation, member-operation
input/review/failure and selection previews carry the normalized hint. Collection
input/review, job detail/refresh and cancellation preserve it too. Successful
generic/member writes return to their current result page with the hint; delete
returns to the permitted list. A changed result may no longer match its original
search, but a return link still leads to that current filtered list.

Global resource/dashboard/job navigation starts fresh. This is request/link
state, not a session-persistent saved view or draft. Normal CSRF, record scope,
current action/field grants and intent/manifest binding remain independent.

## Preserve Queryless Form Recovery

[Form Session Recovery]({% link _advanced/form-recovery.md %}) retains queryless
form actions and recovery URLs. It sends the same intent UUID in its existing
header and carries navigation separately in `X-RailsAiAdmin-Return-State`.
The server-generated value is ASCII Base64URL of UTF-8 JSON, not raw JSON or a
URL. Unicode search text therefore survives the header boundary.

```ruby
encoded = hint.encoded
restored = RailsAiAdmin::Navigation::ListState.from_header(access, encoded)
```

The encoded header is at most 2,048 bytes and decoded JSON at most 1,536 bytes.
Missing/empty means no hint. Bad encoding, invalid UTF-8/JSON/shape or stale grants
are discarded/narrowed under the same current authorization rules, with the
native discard notice. The refreshed recovery form carries the discarded flag,
so its in-tab restored notice also explains when list settings changed. Recovery
responses also vary by this header. Encoding
carries no identity, record or write authority, and a discarded hint does not
change the same-intent recovery requirement or cause write replay.

## Retain Navigation Helpers in Overrides

Templates receive `@list_navigation` where listed in the
[Template Catalog]({% link _reference/template-catalog.md %}). Use the registered
Rails view helpers rather than interpreting raw `params[:return_to]`:

| Helper | Contract |
| --- | --- |
| `navigation_state` | Normalized plain Hash, empty if absent/discarded |
| `navigation_params` | Nested return_to route params, or empty Hash |
| `return_navigation_fields` | Escaped hidden fields for normalized state |
| `list_return_path`, `list_return_label` | Current resource index or dashboard fallback |
| `list_page_path(integer)` | Current index page, bounded to 1..1000 and canonical first page |
| `encoded_return_state` | Server-produced bounded recovery-header value |
| `return_state_discarded?` | Whether normalization removed invalid/unavailable state |

Preserve header form data, hidden return fields, permitted sort headers and the
discard notice/return-discarded recovery flag when overriding templates. `resource_index` also receives
`@sortable_fields`; it does not authorize a hidden output column merely because
it is sortable. The navigation object remains a hint even inside trusted Rails
templates. There is no generic redirect-to-client-URL helper, saved-view feature
or completion of the full navigation/release roadmap.

## Next Steps

* [Resources and Fields]({% link _core_features/resources-and-fields.md %}) separates readable output from query grants.
* [Form Session Recovery]({% link _advanced/form-recovery.md %}) preserves open-DOM input without drafts or automatic Save.
* [Template Overrides]({% link _advanced/template-overrides.md %}) explains context revisions for navigation-aware copies.
