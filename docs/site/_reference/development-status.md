---
layout: default
title: Development Status
nav_order: 5
guide: false
description: Read the supported development slice and the gates still required for release.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

See [What's New in 0.1]({% link _getting_started/whats-new-in-0-1.md %}) for
the Public Preview scope, supported workflows and limitations.

Current code includes explicit resources, fresh host contexts, custom default-deny
policy contracts and an optional Pundit adapter with an explicit policy per
resource, independent field grants, readonly resources, scalar forms,
bounded search/sort/pagination, typed inputs, optimistic locking, server-issued
intents, atomic receipt/audit writes, closed install/resource scaffolds, schema-only
commented field suggestions, diagnostic metadata and an initial TestKit with
anonymous-context and exact field-grant assertions. The code also implements
registered synchronous member operations, pure/input-bound confirmation, separate
operation-input/receipt/delivery grants and a typed durable outbox with stable
request binding, leases and bounded recovery. Fixed Selection manifests now
capture/revalidate up to 100 explicit canonical IDs and record versions through
separate default-deny selection permission and native no-JavaScript previews.
Collection operations now bind those manifests to one parent approval and
durable per-target child intents/items. A worker uses the shared Runner with fresh
authority, lease fencing and independent target transactions; native job receipts
and cancellation preserve committed results. These capabilities still require
host-specific validation. Field-grant snapshots do not substitute for
action/scope checks or constitute an AI exposure report. Registered scalar field
types now supply pure normalization/validation, constrained wire schemas and
field-level partials; [Field Types]({% link _core_features/field-types.md %})
documents this limited extension contract.
[Computed Fields]({% link _core_features/computed-fields.md %}) adds versioned
readonly scalar computations over explicit recursively granted dependencies, with
graph/snapshot/output/budget limits and per-record projection caching. It supplies
no virtual writes/search/sort or general model-method invocation.
[Template Overrides]({% link _advanced/template-overrides.md %}) now provides
allowlisted page/layout/partial copies with explicit context metadata and bounded
source/contract inspection. CURRENT metadata does not certify host edits. Per-view field flags, optional
presentation narrowing and bounded form plans now support escaped help text,
tabs/panels and separately authorized readonly context. Writable-only prefills
do not reveal unreadable database values.
[Form Session Recovery]({% link _advanced/form-recovery.md %}) now preserves only
the original open generic create/update DOM across marked authentication/CSRF
failures, with fresh authentication, same-intent renewal, manual Resume and
explicit Save. Persistent session drafts and custom-operation/delete recovery
remain unavailable. These changes do not close Phase 2 or any release Gate.

[Associations]({% link _core_features/associations.md %}) adds `belongs_to`
reference fields with a search picker for large targets, readonly `has_many` and
`has_one` panels with an Add link that prefills the parent, and `references`
fields that edit has_many/through/HABTM lists. Labels, pickers, writes and child
lists go through each target or child resource's own relation and grants.
Association search/sort, polymorphic writes, nested child forms and
attach/detach policies remain open.

Everyday admin features are implemented locally (2026-11-13): records without
`lock_version` use `updated_at` as their version; field types cover time, email,
URL, JSON, write-only passwords, Active Storage `file`/`files` and Action Text
`rich_text`; CSV export and checked CSV import, bulk delete over a selection,
record History and an Audit log, dashboard metrics and trends and a search
across resources each sit behind their own default-deny grant. `bin/demo` shows
all of them. See [Try the Demo]({% link _getting_started/demo.md %}).

[List Navigation]({% link _core_features/list-navigation.md %}) now retains
bounded search/sort/page hints across native resource/operation/selection/job
flows, rechecks current query grants and recovers empty later HTML pages with a
bounded same-scope requery. These hints are neither URLs nor authority; saved
views and the wider navigation roadmap remain separate work.

[Custom Controllers and Status Pages]({% link _advanced/custom-controllers.md %})
adds a host-owned Rails controller base with fresh Context/access/Runner helpers,
explicit mounted-engine routes and fixed independent status presentation. It
does not inherit host controller concerns automatically or replace arbitrary
exception handling. Default record denials retain anti-enumeration 404.

[Resource Navigation]({% link _core_features/resource-navigation.md %}) now
provides static group/label/fixed-icon/order/hidden-menu settings over fresh index
grants. Immutable request-only snapshots contain no records or counts; hiding a
menu never changes direct authorization or operation/Selection fingerprints.
Registration rejects an unusable fallback label. Both packaged hosts render the
grouped menu from current grants; Host A's real reload observed a renamed menu
and Host B rendered a host resource_navigation override on both asset pipelines.
No browser/accessibility check was made for the menu.

[Named Scopes]({% link _core_features/named-scopes.md %}) now adds declared index
tabs with an optional default. Each scope needs an independent default-deny grant
and is intersected with the policy relation by primary key, so a body cannot
widen it. List hints carry the scope and drop revoked grants. Both packaged hosts
verify role/Pundit grants; Host A observed a renamed label after real reload, and
a Chromium check covered keyboard switching at desktop and 320px widths.

[Typed Filters]({% link _core_features/typed-filters.md %}) add exact and inclusive
range conditions on declared scalar fields behind an independent default-deny
filter grant. Values are coerced through each field's contract and bound by Arel;
hints carry canonical nested filters and discard revoked ones. Both packaged
hosts verify role/Pundit filter grants and Host A's real reload; a Chromium check
covered keyboard use at desktop and 320px widths. The Phase 3 Filter AST (OR,
nesting, associations, null tests), saved views and scope counts remain open.

[Index Tables]({% link _core_features/index-tables.md %}) add declared columns, a
grant-dependent default sort, page sizes and bounded exact counts, with a narrow
table layout verified in Chromium. User column choice, keyset pagination and the
full Phase 2/release Gates remain open.

[Review Surfaces]({% link _advanced/review-surfaces.md %}) are the first AI-facing
slice: an opt-in persistent rails_tool_views Surface that confirms the same
native intent once through the shared Runner, via admin-owned endpoints that
never change the host's rails_tool_views settings. Packaged Host B proves
coexistence with its product Surface.

The opt-in [Admin Assistant]({% link _advanced/admin-assistant.md %}) adds a
persisted RubyLLM chat with grant-filtered read tools and proposals that become
review Surfaces. A confirmed review writes once and continues the conversation
once. Turns run through a leased, fenced inbox that recovers after crashes
without repeating the human message. Evidence uses RubyLLM's real provider and
tool loop against offline fixtures, packaged Host B and a Chromium check, plus
one live run per model family through OpenRouter on an earlier build. Current
Chat supports streaming and server-checked context from record and list pages.
The same grant-filtered tools are available through the optional
[MCP server]({% link _advanced/mcp-server.md %}).

The current collection workflows use fixed selections of up to 100 records.
All-filtered selections, saved views, global custom operations, custom CRUD
handler replacement and a general reconciliation UI are future work. The Devise
consumer demonstrates host-owned authentication.

Fixed selections persist only owner/contract/count/digest/expiry and target
ID/version/position metadata. They do not persist queries, labels or business
payload. Capture itself creates no OperationRun/audit/job records and approves
no operation. The separate collection preflight persists bounded typed input on
a parent intent; human confirmation admits its exact targets, and each target
commits independently. Hosts must provide fresh job contexts, persistent queues
and recurring scans; automatic dispatch defaults to false. See
[Fixed Selections]({% link _core_features/selections.md %}) and
[Collection Operations]({% link _core_features/collection-operations.md %}). The
bounded implementation remains a prerequisite for the full planned batch workflow,
not a narrowed replacement for that scope.

Durable Work delivers one declared effect for an already committed operation.
The host must schedule scans, rebuild current authority and verify the actual
downstream idempotency/unknown-outcome protocol. It does not prove downstream
exactly-once behavior or complete the asynchronous-workflow roadmap. A collection
item can succeed while its separate Work remains pending or needs reconciliation.

The checkout's `COMPATIBILITY.md` and `ROADMAP.md` identify executed evidence and
remaining milestones. In-repository tests, packaged-consumer tests, actual browser
checks, paid providers, human usability work and independent security review are
different evidence. Do not substitute one for another.

The native-session consumer now also has an Order model/resource and ordinary
host-owned review workbench under /staff/workbench/orders/:id. Native actions and
the workbench share ReviewOrderOperation and its input-bound intent/receipt;
packaged cases cover decimal/date/false input, validation/readonly state,
scoped role/tenant restrictions, one execution with cross-UI replay and stale/
tampered confirmation rejection. Admin-only review notes and hidden payment tokens
remain outside unauthorized projections. See the concrete source map in
[Custom Controllers and Status Pages]({% link _advanced/custom-controllers.md %}).
The Order host's actual reload probe replaced controller/resource/operation/
registry and observed new HTTP code while rejecting old-version approval without
business mutation. That Order/controller checkpoint passed production eager
loading and its recorded catalog render probe; new menu-milestone runs are
reported separately. Chrome exercised explicit workbench review/confirmation,
readonly approved-edit denial and generic Order same-UUID session recovery with
decimal/date/false input, empty local/session storage and a single explicit Save.
The custom layout's CSP nonce matches its header; its preview uses ordinary Rails
full-page confirmation, and the checked 390px dark workbench had no horizontal
overflow. This targeted author-controlled evidence establishes no Surface, AI,
provider or independent user behavior, and does not close broader Phase 2 work or
release Gates.

The native-session SQLite consumer and independent Devise/Pundit/PostgreSQL support
consumer provide packaged integration evidence for this limited slice. Host B also
exercises actual Rails development reload and fresh-process crash/replay probes.
These author-controlled synthetic hosts do not establish independent usage, full
Admin P0 coverage or production readiness.

Release Gates A through E remain open, including completion of all required
packaged-host workflows, real provider validation with an approved budget, migration samples and
explicit owner release approval. No remote deployment or gem publication is
performed by the current local build commands.
