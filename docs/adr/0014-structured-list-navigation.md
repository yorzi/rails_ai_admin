# ADR 0014: List return locations are structured hints within one resource

Status: implemented development contract; Phase 2 and release gates remain open.

`return_to` is a map containing only `q`, `sort`, `direction` and `page`, never a
URL or Rails routing-options hash. Values are bounded strings; defaults disappear
from the canonical snapshot. Search accepts valid UTF-8 or ASCII, at most 200
characters and no C0/DEL controls. Sort names are bounded identifiers, direction
is asc/desc and page is 1..1000. Invalid shapes, unknown routing keys and malformed
member hints discard the hint with a notice. No Referer, browser storage, session
preference or remembered host/alias is used to determine a destination.

Each request resolves current index/search/sort grants for the current Resource.
Removed query grants drop their settings and reset page; an unavailable index
returns to the Engine dashboard. Named routes always generate the current
resource's list URL, including the actual mount/relative-root prefix. These hints
carry no authority, record identifiers, manifest membership or command input.
They are excluded from approval/digest/idempotence identity. Sharing a URL causes
normal fresh authorization rather than restoring another user's grant snapshot.

HTML index validates syntax before querying. Structurally unsupported/virtual sort
targets still produce INVALID_QUERY. A declared setting whose current grant was
revoked redirects once to the remaining valid list settings, with a notice.
The public Query API remains strict rather than silently applying that HTML
fallback. Search/page encoding guards return INVALID_QUERY before adapter
serialization; NUL search and malformed UTF-8 page previously raised Ruby/adapter
ArgumentError. Those were framework validation defects, not upstream gem bugs.

Index links preserve the canonical map through show/new/edit/delete, member action
review, fixed selections, collection review and job refresh/cancel. Mutation URLs
stay queryless; hidden metadata is separate from record/input/confirmed_input.
Success retains the existing record-show behavior and carries the hint onward;
delete returns directly to the list. Validation/conflict pages keep it too.
Discard notices survive successful redirects. Explicit global/sidebar navigation
starts a new navigation context.

Search retains current sort and resets page. Authorized visible sortable headers
provide ordinary links, aria-sort and a primary-key tie-breaker. Pagination keeps
query/sort; the first-page link omits the default page. The UI offers no next-page
link past 1000 and asks the user to narrow the search instead.

For HTML only, an empty requested page above 1 triggers a bounded count of the
same authorized, filtered relation, followed by at most one clamped requery and a
303 canonical redirect. The count limits matching rows to requested_page * 25,
at most 25,000; this does not bound the physical rows an unindexed database filter
might inspect. Concurrent changes remain best-effort: there is no retry loop or
cross-request snapshot. Query callers opt in with recover_empty_page: true;
default callers retain the previous empty-page behavior. Deleting the final
matching row cannot widen to another tenant or a different filter.

Open-tab form recovery sends the server-generated ASCII Base64URL UTF-8 JSON
snapshot in X-RailsAiAdmin-Return-State. Raw JSON cannot safely carry Chinese/emoji
in a browser Headers ByteString. The server limits encoded input to 2048 bytes,
decoded JSON to 1024 bytes, then applies the same shape/current-grant rules.
The UUID stays in its separate header, and the business/recovery URLs remain
queryless, preserving exact action binding and the original intent. Vary includes
the new header. Fresh hidden navigation fields replace old fields; stale or bad
hints get a visible notice inside the imported form, not just its outer layout.
The encoding is not encryption, a signature or authority.

The catalog still has 24 paths. New/edit/shared form contexts advance to revision
4; other navigation-aware page contexts advance to 2. Explicit list_navigation
assigns expose an immutable scalar hint/flags, not an access object; index also
supplies sortable_fields. See the installed catalog for unchanged field contexts.

Contract/request tests verify injection rejection, current-grant fallbacks,
UTF-8/header bounds, unchanged business replay identity, filtered page deletion,
stable tied sorts, member review and selection-to-job/cancel propagation. Both
packaged hosts verify Unicode navigation and recovery. Chrome verifies a
Chinese/emoji page-2 list through edit, session rotation, manual Resume and Save;
removing the final match clamps to page 1, sort toggling and browser Back preserve
state, and an injected malformed hint safely resets links while retaining input.
No application JS/CSP error was seen; an expected CSRF 422 network entry remains.

This advances RAA-0207/0212 and LIST-016. Status/controller extension, three-domain
Phase 2 acceptance, association/filter ASTs, saved views and larger workflow gates
remain open.
