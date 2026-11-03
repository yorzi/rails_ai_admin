# ADR 0021: belongs_to references resolve through the target resource's grants

Status: implemented development contract; RAA-0301 and the Phase 3 gate remain open.

`fields { belongs_to :customer, resource: :customers, foreign_key: "customer_id" }`
declares a reference field. Its name is the association name, so policies,
forms, errors, audit and list hints use `customer`; `Field#column` is the
physical `customer_id` column that reads, writes, filters and doctor checks use.
Every other field type keeps `column == name`. The value is the target primary
key as bounded opaque text. Integer and UUID keys share one wire contract, and a
record is never accepted as input.

Registration fails when a target resource is not registered, so a typo cannot
render as a permanently unavailable reference. Model reflection is not loaded at
boot. First use and doctor require a non-polymorphic `belongs_to` whose foreign
key is the declared column and whose primary key is the target's single primary
key. Search and sort are rejected until LIST-019 defines registered joins.
Filters offer `eq` only, behind the existing independent `:filter` grant.

**Reads.** A reference is labelled only through the target resource: its current
policy relation, record show grant and the shared `record_label` title contract.
A visible target links to its show page. A target that is missing, in another
tenant or not shown renders the same unlinked `Customer #42` placeholder, built
from the key the source field grant already exposes. `Fields::Association` is a
request-local resolver; the index primes each reference column with one target
query, so a page costs one query per column, not per row. A Host A acceptance
assertion and a mutation that disabled priming confirm that guard.

**Writes.** The shared Runner checks references after input coercion, inside the
write transaction and before the domain save. A changed reference must name a
target that is visible now. A missing, foreign or hidden target gets the same
`is not an available choice` error, so writes cannot probe existence. An
unchanged stored reference is accepted without visibility: keeping an existing
value is not a new attachment, and requiring visibility would force an actor to
clear a reference just to edit another field. Forms therefore keep that value
selected as `(not available)`. When the target is deleted between the check and
the insert, a foreign-key constraint raises `InvalidForeignKey`, which now maps to
CONFLICT with full rollback instead of an unhandled error. Without a database
constraint that race can still leave a dangling key; doctor's association check
says so.

The field write grant is the reparenting authority. CRUD-021's separate
attach/detach/reparent policies, old-parent checks and dependent-destroy
previews are not implemented; this ADR does not close it.

**Pickers.** Forms and filter forms list at most 100 targets the actor may index
and see, ordered by the target title only while its sort is granted (ordering by
an ungranted title would leak its relative values), then by primary key. Past
100, or without a target index grant, the form takes a typed key that the same
write check validates. A searchable options endpoint
(`GET /:resource/associations/:field/options`) remains planned.

**has_many panels.** `has_many :orders, resource:, via:, label:, limit:` adds a
readonly show-page panel (CRUD-024 subset). Children come from the child
resource's policy relation narrowed by its own reference column, with the child
index grant and a read grant on that reference field. Listing children by parent
would otherwise reveal a value the actor cannot read. Rows link only with the
child show grant. "View all" links to the child list filter only while the child
reference field is filter-granted, so the link never fabricates an ungranted
query. Panels are bounded (1..50 rows, 10 per resource), ordered by primary key
and add no write path. Pagination inside a panel, child row actions and counts
remain open.

**Templates.** `field_reference` and `resource_associations` join the override
catalog (29 entries). `resource_show` advances to revision 3 (new
`association_panels` assign) and `field_form` to revision 2 (reference picker
branch), so doctor flags older host copies for review.

Contract and request tests on SQLite and PostgreSQL cover the declaration
contract, registry and reflection validation, one-query priming, indistinguishable
unavailable targets, bounded and grant-ordered choices, visible-only writes,
unchanged and cleared references, a vanished-target race, filters, panels and
escaping. Mutations that removed the write check, the batch priming and the
foreign-key mapping each failed the suite. Packaged Host A declares
`Order belongs_to :customer` and `Customer has_many :orders`. Its acceptance test
covers tenant-scoped links, pickers, writes, the panel and its filtered list, and
the override run renders both new partials. Host B is unchanged and passes on
both asset pipelines.
