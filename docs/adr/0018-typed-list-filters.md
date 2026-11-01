# ADR 0018: Typed list filters need an independent field grant

Status: implemented development contract; Phase 2/3 and release gates remain open.

Fields opt in with `filterable:`. `true` selects type defaults: `eq` for
id/text/textarea/enum/select/boolean and inclusive `gte`/`lte` for
integer/decimal/date/datetime. An Array narrows to distinct allowed operators
(range types also allow `eq`), normalized to the fixed `eq, gte, lte` order.
Text-like fields only support exact equality; contains/prefix matching remains
search. Virtual fields and anything else (Strings, unknown operators, empty
lists, `gte` on text) are configuration errors. Hidden fields never filter.

Field options are part of operation/Selection fingerprints (as search/sort already
are). `filterable` therefore has no default entry: undeclared fields keep
byte-identical contracts and upgrading invalidates no in-flight intent or
manifest. Adding or removing a declaration changes that resource's fingerprint,
like any other field option change.

Filtering reveals values through record membership even when the column is not
displayed, which SEC-017/FAIL-05 treat as inference. The adapter's existing
`fields(action:)` therefore gains `:filter` (Pundit: `filterable_fields`). It is
default-deny and not implied by read, search or sort. `Access#fields(:filter)`
intersects the grant with declarations. An adapter that returns one fixed list for
every action would grant filters too, as it already grants search/sort/write; such
an adapter should switch on `action`.

`Queries::List#call(filters:)` accepts `{ field => { operator => String } }`,
ANDs at most 20 conditions (the plan's Filter AST bound) and treats every field
as a current-grant check. Each value is a 1..200 character UTF-8/ASCII string
without C0/DEL controls and is coerced through the field's scalar contract,
including registered field-type normalization and the Context time zone for
datetimes. Coerced values are bound by Arel predicates on the declared column.
No column, operator or SQL text comes from input. Undeclared, ungranted,
malformed or out-of-contract conditions are INVALID_QUERY; the query API never
drops conditions. Filters apply after the named scope and compose with search,
sort, pagination and empty-page recovery. Text equality follows the database
collation (case-sensitive on default SQLite/PostgreSQL). NULL filtering, OR
groups, nesting, associations and saved views are out of scope.

List hints add a nested `filter` map. Blank conditions are dropped, field and
operator order follow the declaration, and depth is fixed at two. Strict index
requests reject undeclared fields/operators and invalid values for granted
fields with 422. Revoked grants (or invalid values in a member hint) are
discarded with the existing notice and page reset. A submitted form whose filter
map differs from its canonical nonblank form receives one silent 303 to the
canonical URL. Hidden return fields use nested names
(`return_to[filter][total][gte]`) through `ListState.form_pairs` and no longer
emit duplicate element ids. Nesting needs more room, so the decoded recovery-header
JSON bound rises from 1,024 to 1,536 bytes. The encoded header stays at 2,048
bytes, so the transport bound is unchanged (supersedes that detail of ADR 0014).

The index renders a native fieldset with labelled typed inputs: selects for
enum/select/boolean, number for integer, decimal-mode text, date and
datetime-local. Search and filter forms each preserve the other's state.
resource_index advances to revision 4 with `filter_fields`. TestKit field
snapshots and exact assertions now include `filter`, which is a deliberate
breaking change for an unreleased API: an omitted group would silently miss a
widened filter grant. Doctor reviews filterable columns that appear in no index.

Contract tests cover declarations, grants, every operator type against real
decimal/date/datetime/enum/boolean columns, time zones, tenant isolation,
composition with scopes/search/sort/recovery, rejected shapes and values, hint
canonicalization/revocation and the Pundit/TestKit/Doctor surfaces on SQLite and
PostgreSQL. Host A filters Orders by admin-only decimal total, delivery date and
flag; real reload removes a declaration. Host B grants Pundit filters by role on
both asset pipelines. A Chromium check of Host A at 1280px and 320px found labelled
inputs, keyboard entry/submission, 44px controls, no page overflow and no console
or CSP errors. No screen-reader check was made.

This completes the filter part of RAA-0201 and a typed subset of LIST-003. The
Phase 3 Filter AST (RAA-0302: nesting, OR, association paths, null tests, quick
filters) remains open and should extend these operators and grants, not replace
them.
