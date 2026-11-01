# ADR 0019: Index table settings order and bound what grants already allow

Status: implemented development contract; Phase 2 and release gates remain open.

`Resource.index { columns ...; default_sort name, :asc | :desc; page_size n;
count :none | :exact }` declares static index presentation. Each option may be set
once; unknown options are configuration errors. Columns are 1..50 distinct
Symbols naming declared, non-hidden fields visible on index. The default sort
names a declared, non-hidden, non-virtual sortable field. The page size is
1..100 (default 25) and count defaults to `:none`. Registration validates every
reference against the declared fields. With no block, the index behaves exactly
as before: declaration-order index fields, primary-key order, 25 rows and no
count. The settings are not part of operation or Selection identity, so changing
the table never invalidates an approval.

Columns order and narrow the fields that current read grants, presentation masks
and recursive dependency rules already allow. They cannot add a hidden, ungranted
or dependency-masked field: a declared virtual column whose dependency the index
mask withholds is still omitted (Host B). The projection computes only the
listed columns plus the title, so unlisted virtual fields are no longer computed
per row. `Access#project(only:)` can only narrow.

The default sort applies only while the actor holds the sort grant for that
field. Ordering by an ungranted field would leak its relative values, so the
list falls back to primary-key order instead. The primary-key tie-breaker always
follows. An explicit `sort` still requires a grant and otherwise remains
INVALID_QUERY. The granted default order is omitted from list hints like the
default scope, so `/orders` and `/orders?sort=delivery_on&direction=desc` share
one canonical URL. `Page` reports the applied `sort`/`direction`, so `aria-sort`
reflects the default order too.

`count :exact` runs `COUNT(*)` over a subquery of the authorized, scoped,
filtered and searched relation limited to 10,001 rows. It reports at most 10,000,
with `count_capped` for more, so a large table never needs an unbounded count.
LIST-018's `:estimated` strategy is deliberately not offered: PostgreSQL/SQLite
table statistics describe the whole table across tenants and filters, so they
would disclose other tenants' volume and mislabel filtered lists. Counts reveal
nothing beyond what paging through the same authorized relation shows.

Pages stay bounded at 1..1000, so the reachable window is page_size * 1000 rows.
Empty-page recovery uses the resource page size.

Table cells now use `overflow-wrap: break-word`, so a column is never narrower
than its longest word, and wider tables scroll inside the focusable region.
Compact machine-formatted values (id, integer, decimal, date, datetime, boolean)
also stay on one line, because ISO dates otherwise break at hyphens. That defect
was found by a Chromium check at 320px. resource_index advances to revision 5
(applied order, optional count, compact cells).

Contract and request tests cover declaration bounds and reference checks,
unchanged defaults, page size, granted/ungranted default sorts, explicit
overrides, recovery, capped counts over 10,005 rows, canonical hints and
narrowing projection on SQLite and PostgreSQL. Host A orders declare columns, a
descending delivery-date default, 20-row pages and counts, and its real reload
turns the count off. Host B orders tickets by priority with counts.
A Chromium check at 1280px and 320px found no page overflow, a scrolling and
arrow-key-scrollable table region, no split words and no console/CSP errors.

This completes the table part of RAA-0201. Column choice by users (RAA-0304),
saved views, keyset pagination and association columns remain open.
