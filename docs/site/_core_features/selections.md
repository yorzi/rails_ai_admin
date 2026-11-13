---
layout: default
title: Fixed Selections
nav_order: 3
description: Capture and revalidate an exact bounded set of currently authorized record versions.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* How to grant selection capture separately from ordinary read/write actions.
* How native checkboxes and the Builder capture exact IDs and versions.
* How to revalidate a manifest without treating it as approval or execution authority.

## Grant Selection Capture Explicitly

Capturing or viewing a fixed selection needs a separate default-deny permission.
Index access alone does not grant it. For the custom policy adapter from the
configuration guide, add this method inside `AdminPolicyAdapter`:

```ruby
def select_records?(context:, resource:)
  resource.key == :customers && context.actor.role == "admin"
end
```

With Pundit, add a `select_records?` predicate to the explicitly mapped resource
policy. For example, inside the support host's `TicketPolicy`:

```ruby
def select_records?
  %w[operator admin].include?(context.actor.role)
end
```

Pundit constructs this policy with the full admin Context and the resource's
**model class**, not an individual record. Do not call a member predicate that
expects record attributes from this collection-level gate. The Builder separately
requires current `index` permission, complete policy scope and `show` permission
for every selected target. Current read-field grants control its label.

A missing selection method/grant denies both capture and revalidation. Granting
selection access does not grant CRUD writes, custom operations, receipt reads or
Work delivery. A readonly resource can permit this metadata-only selection flow
without acquiring business-write authority.

## Capture From the Native Index

When those grants permit it, the resource index shows record checkboxes and a
**Capture selection** form. The current native form selects explicit records on
that page; it does not implement an all-filtered selection or persistent selection
across pages. It works without JavaScript.

Relative to the engine mount, the flow is:

| Request | Behavior |
| --- | --- |
| `POST /:resource/selections` with `target_ids[]` | Capture exact authorized IDs/current versions; redirect with 303 |
| `GET /selections/:selection_ref` | Revalidate and display the current authorized labels, IDs and bound versions |

The form uses the host session and normal CSRF boundary. A success means selection
metadata was saved, not that a business operation was approved or executed. Capture
creates no `OperationRun`, business audit event, Work item or job.

A record that later begins matching an index search is never added automatically.
Changing a selected record requires a fresh selection; the current preview does
not silently substitute a replacement record with the same display name or count.

## Use the Builder With Explicit Targets

Given the current authenticated `context`, registered `CustomerAdmin` and two
currently visible customers from its tenant:

```ruby
builder = RailsAiAdmin::Selections::Builder.new
selection = builder.capture(
  context: context,
  resource: CustomerAdmin,
  target_ids: [customer.id, second_customer.id]
)
```

`capture` returns a `Selections::Builder::Snapshot`. Its fields are:

| Snapshot field | Meaning |
| --- | --- |
| `selection_ref` | Server-issued opaque selection ID |
| `resource_key` | Registered resource key |
| `manifest_digest` | Binding of the exact canonical targets/versions and resource contract |
| `expires_at` | Capture expiry derived from `config.intent_ttl` |
| `targets` | Immutable ordered list of `Selections::Builder::Target` values |

Each Target has `id` (a canonical string), `expected_version` (the captured
record version: `lock_version`, or `updated_at` in microseconds) and `label` (a current permitted display label). Target order is
canonical and deterministic; it does not preserve caller order or depend on labels.
The digest is a manifest commitment, not an authorization token. Record identity
includes stable model/table/primary-key metadata, so a deployment that remaps IDs
invalidates an old manifest instead of redirecting it to a different row.

The list must contain 1 through 100 explicit, distinct canonical IDs. Strings and
integers are accepted for compatible integer/string/UUID primary keys. IDs that
normalize to the same target, such as integer `7` and string `"07"` on an integer
key, are rejected rather than silently deduplicated. Empty, oversized, malformed
or wildcard inputs such as `"all"` are not a query-selection API. Every requested
target must be currently visible; capture does not silently drop unauthorized or
missing IDs and save a smaller set. Authorized joins may duplicate rows; lookup
derives a DISTINCT primary-key subquery from the complete policy scope, then
loads only those IDs with a bound. It does not broaden the saved selection or
expand an unscoped query into new targets.

The domain model, `Selection` and `SelectionItem` must share one SQLite or
PostgreSQL connection pool. The model needs one primary key and a record
version: `lock_version` optimistic locking or an `updated_at` timestamp. Composite keys, another pool and other
database adapters are not supported by this capture contract.

## Revalidate Before Using a Preview

```ruby
fresh = builder.revalidate(
  context: context,
  selection_ref: selection.selection_ref,
  resource: CustomerAdmin,
  manifest_digest: selection.manifest_digest
)
```

`resource` and `manifest_digest` are optional; supplying them also verifies the
current registered resource and expected digest. Revalidation returns a fresh
Snapshot of the same targets, never an expanded query result. It checks:

* Actor/tenant ownership, current security version and expiry.
* Current resource contract, including physical table and primary-key name/types,
  stored count/order/digest consistency and any supplied digest.
* Current selection/index/show grants and complete record scope.
* Each exact target's current record version against its captured version.

Current read-field grants are used again for labels. A hidden title becomes the
safe `Record #id` fallback instead of exposing a saved label. The engine does not
persist labels or arbitrary business values in a manifest. A legitimate version
change causes conflict before showing a replacement label; newly matching records
and same-count target replacements cannot make an old manifest valid.

A successful check is a fresh read, **not a record lock or authorization for a
later write**. State can change immediately afterwards. The separate
[Collection Operations]({% link _core_features/collection-operations.md %}) flow
binds the exact manifest at parent approval and checks each target version/current
permission again in its execution transaction. Passing a selection to a member
API cannot create a batch executor.

## Interpret Expiry and Invalidations

The Ruby API raises `AccessDenied` with stable codes for ordinary denied/changed
requests. Native requests use generic messages rather than revealing target data:

| Condition | Current response |
| --- | --- |
| Expired selection | `SELECTION_EXPIRED`, HTTP 409 |
| Security/resource contract or supplied digest changed | `SELECTION_INVALIDATED`, HTTP 409 |
| Selected target version changed | `CONFLICT`, HTTP 409 |
| Missing/foreign target, owner/tenant mismatch or denied current grant | Generic not-found response, HTTP 404 |
| Invalid explicit-ID input | `INVALID_QUERY`, HTTP 422 |

Missing authentication remains 401. A corrupt stored manifest is a configuration/
integrity failure, not permission to replace targets; the native controller gives
its generic unavailable response. Capture/revalidation perform their target lookup
under an Active Record read-only guard. As with other trusted host callbacks,
that guard is not a Ruby sandbox or proof that arbitrary policy code is pure.

## Keep Capture and Operation Admission Separate

The immutable parent row stores owner/tenant/security version, resource fingerprint,
count, digest and expiry. Item rows store only target ID, expected version and
position. It does not store the index query, filters, labels or business payload.
Parent/item model instances are readonly after persistence through the normal model
API; direct SQL/database administrators remain outside that boundary. No selection
editing or automatic refresh of expired manifests is supplied.

This manifest is the fixed-target prerequisite for bounded asynchronous collection
operations. Their separate preflight creates a parent intent; explicit human
confirmation admits durable child intents/items. Capture itself supplies neither
approval nor execution authority. The original selection must still be valid at
admission; admitted execution uses its approved exact manifest and a separate job
deadline rather than extending the selection.

All-filtered capture, 10,000-target manifests and a complete job center remain
planned. The full batch/async scope and release Gates remain required; this
bounded implementation does not narrow those goals.

## Next Steps

* [Collection Operations]({% link _core_features/collection-operations.md %}) binds a manifest to explicit approval and per-item execution.
* [Operations]({% link _core_features/operations.md %}) explains synchronous member commands and confirmation.
* [Configuration]({% link _getting_started/configuration.md %}) establishes current context and complete scopes.
* [Development Status]({% link _reference/development-status.md %}) separates implemented prerequisites from remaining workflows.
