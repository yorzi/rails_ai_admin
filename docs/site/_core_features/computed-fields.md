---
layout: default
title: Computed Fields
nav_order: 6
description: Derive readonly scalar values from explicitly declared and currently authorized dependencies.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* How to declare a virtual field with a named computation.
* How recursive dependency grants control its visibility.
* How snapshots, projection caching and bounds constrain computation.
* How computed values interact with titles, operations and reload.

## Declare a Readonly Scalar Computation

Use a virtual field when a displayed scalar depends on other declared fields.
For a host `Customer` model with `name`, `points` and `account_id` attributes:

```ruby
class CustomerSummary < RailsAiAdmin::Fields::Computation
  version "1"

  def call(values, field:, time_zone:)
    "#{values.fetch('name')}: #{values.fetch('points')} points"
  end
end

class CustomerAdmin < RailsAiAdmin::Resource
  model "Customer"
  key :customers
  title :summary

  fields do
    id :id
    text :name
    integer :points
    virtual :summary, type: :text, depends_on: [:name, :points],
      compute: "CustomerSummary", nullable: false, max_length: 200
  end
end
```

`compute:` is a class-name String, resolved fresh through Rails loading. The
named class inherits `Fields::Computation` and has a compatible public
zero-argument constructor. Its public hook is exactly
`call(values, field:, time_zone:)`. It receives the frozen dependency Hash with
string keys, a frozen field descriptor and the current time zone, not a record,
controller, policy or unrestricted resource-value Hash.

No separate computation registry is needed. `type:` can name a built-in scalar
or registered [Field Type]({% link _core_features/field-types.md %}). The returned
value goes through that field's normal scalar/plugin coercion and constraints.
It must become that scalar; arbitrary objects, records, nested Hashes and Arrays
are not a computed-output contract. Display follows normal text formatting and
Rails escaping, including when a field type supplies a display partial.

## Grant the Field and Every Dependency

A computation declaration grants no read access. For a minimal readonly example,
a host adapter can make its complete tenant scope and read decisions explicit:

```ruby
class CustomerSummaryPolicy < RailsAiAdmin::Authorization::Adapter
  def scope(context:, resource:, relation:)
    relation.where(account_id: context.tenant.id)
  end

  def allowed?(context:, action:, resource:, record: nil)
    context.actor.role == "admin" && [:index, :show].include?(action)
  end

  def fields(context:, resource:, action:, record: nil)
    action == :read && context.actor.role == "admin" ?
      [:id, :name, :points, :summary] : []
  end
end
```

Register the resource and policy alongside the host's existing fresh Context
adapter; this example grants no write action or selection permission:

```ruby
RailsAiAdmin.configure do |config|
  config.authorization_adapter = "CustomerSummaryPolicy"
  config.resources = ["CustomerAdmin"]
end
```

Given that authenticated current `context` and a visible customer's ID:

```ruby
access = RailsAiAdmin::Authorization::Access.new(context, CustomerAdmin)
customer = access.find!(customer_id)
values = access.project(customer)
summary = values.fetch("summary")
```

The engine first intersects the current read grants with declared fields. A
virtual field survives only if its own grant and **every recursive dependency's
own grant** survive. A dependency can itself be virtual; all intervening nodes
and physical leaves must be granted. Denying `:name` hides `:summary` before its
computation or denied getter runs. Denying only `:summary` also hides it even if
name/points remain readable. This is not a declassification mechanism for a
confidential field's aggregate.

Computed fields are always readonly with create/edit/search/sort disabled.
Declarations that try to widen those options fail configuration; returning them
in write/search/sort policy grants cannot enable those capabilities. Forged input
cannot assign the computed value. Query search/sort remains based on eligible
physical fields, not arbitrary Ruby methods or generated SQL expressions.

## Validate the Dependency Graph Without Reading Domain Data

Every dependency must name a distinct declared field. Cycles and missing fields
fail resource validation. Resources with virtual fields support at most 128 total
declared fields, 20 direct dependencies per computation and eight virtual levels
in a dependency chain. Registration validates graph metadata without consulting
domain rows or schema; runtime physical leaves still require actual attributes.

A DAG is evaluated with one cache per record projection. Shared dependencies and
computed nodes are read/evaluated once in that projection, including a diamond
of dependencies. The cache is not shared across requests, actors or records.
Native index rows reuse the row's projection for its title and values. Calling a
new projection later performs fresh permission checks and recomputation; it does
not return historical cached data.

## Keep Snapshot Computation Pure and Bounded

`values` contains only this computation's declared dependency snapshots, not
other readable fields. Supported snapshots are nil, booleans, Integer, String,
finite BigDecimal, Date and temporal values. Strings/Dates are copied; Time,
TimeWithZone and DateTime become UTC Time copies. Values and the containing Hash
are frozen without freezing or changing the caller's temporal object. Unsupported
objects are rejected rather than stringified into a snapshot.

Each dependency value and its complete dependency Hash must fit 16 KiB when
canonically serialized. Each computed scalar also fits 16 KiB, and the combined
computed outputs in one record projection fit 64 KiB. Field-specific scalar
length/schema limits still apply. A projection containing computed fields has a
cooperative one-second budget checked before/after every field, including physical
reads and the final field, and before returning all values. These checks do not
interrupt a long Ruby hook, SQL or I/O while it is running.

Dependency reads, the hook and result coercion run under Active Record
`while_preventing_writes`. All physical attribute getters also use this guard,
including reads cached before a computation and physical title reads. Ordinary
Active Record writes are blocked. This is not
a trusted-Ruby sandbox: the host must keep hooks and real-attribute getters pure,
with no external calls, raw writes, record lookup or explicit confidential logging.
A frozen snapshot is not permission to fetch additional data through host code.
Bad output, mutation, bounds or ordinary hook failure becomes a configuration
failure; native requests use the generic unavailable response instead of exposing
the original computation diagnostic.

## Preserve Titles and Business Evidence

A virtual field can be the resource title. Native pages, Selection previews and
collection-job receipts share `Field.format` and truncate the resulting label to
120 characters. Boolean No/Yes, select labels, datetime text and plugin formatting
therefore follow the same contract. When the title's own or a dependency's read
grant is missing, labels fall back to `Record #id`. It does not become a stored label or a reason to
call a hidden model method. The existing physical-attribute guard still rejects
attempts to expose methods such as `destroy` through physical field declarations.

Operation and Work input schemas cannot declare computed fields. Custom preflight
cannot fabricate a virtual before/after change: the preview excludes virtual
change entries. After a business write, the actual current authorized projection
recomputes its values. Committed receipt reads also use current dependency grants
rather than a saved confidential summary.

`Field.contract` includes computation class/version and dependency metadata in
addition to scalar/plugin constraints. Changed contracts invalidate affected
operation, Selection and Work fingerprints. Bump the computation's `version`
when semantics change; method bodies are not automatically hashed. Reload/rebuild
resource definitions and reopen invalidated forms or capture fresh Selections.
A live computation detecting changed metadata fails closed until definitions
reload. There is no migration that rewrites old approval evidence.

This supports bounded, readonly scalar computation, not arbitrary model methods,
SQL-calculated sorting, association traversal, full-page overrides or completion
of Phase 2. The remaining product roadmap and release Gates still apply.

## Next Steps

* [Field Types]({% link _core_features/field-types.md %}) refines the scalar output contract and display.
* [Extension Contracts]({% link _reference/extension-contracts.md %}) lists exact signatures and limits.
* [Resources and Fields]({% link _core_features/resources-and-fields.md %}) explains physical exposure and query grants.
