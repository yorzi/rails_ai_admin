---
layout: default
title: Dependency Contracts
nav_order: 4
description: Understand selected dependency guarantees, resolved installer reports and integration limits.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* Which released dependency lines the gem selects.
* How the host owns the documented shared Surface runtime.
* How to preserve a custom mount when running the released Surface installer.
* How Rails callback semantics affect operation results.

## Use Released Dependency Lines

The gem currently bounds Rails to 8.1.4 through below 8.2, `rails_tool_views` to
1.0.2 through below 1.1, RubyLLM to 2.1.1 through below 3, `turbo-rails` to 2.x and
`stimulus-rails` to 1.x. Refer to the lockfile for the exact resolved graph. A
candidate range does not prove all future versions in that range are compatible.

Conventional installation does not provision assistant tables or configure a
provider. No paid provider call is part of default development tests. RubyLLM main
APIs such as unreleased queue/claim/approval primitives must not be assumed present
in the selected released package.

## Adopt the Host-Owned Shared Runtime

The selected `rails_tool_views` 1.0.2 Configuration guide explicitly documents one
configuration, registry and mount per process. The host owns `scope_resolver`,
`parent_controller`, `agent_adapter` and `auto_deliver`; action forms use the named
`rails_tool_views` mount. A registering gem uses its own component-key prefix and
declares the host scope/policy/adapter contract instead of overwriting globals.

DEP-001 is closed as this documented contract. The release adds no isolated
runtime configuration. The current admin preserves the host product's settings;
admin Surface identity/routing/continuation still needs its planned acceptance.
The dependency's stable core does not make the experimental adapter stable.

## Preserve an Existing Surface Mount

DEP-006 is fixed in 1.0.2: the installer skips an existing root-file Engine mount
instead of appending another route with the same alias. The packaged support smoke
reruns that released installer, asserts unchanged route source and checks that
the named path remains `/product_surfaces`. It no longer restores routes to hide
the 1.0.1 defect and applies no dependency monkey patch. This proves that concrete
case, not every alternate Rails route spelling or drawn layout.

Review generated initializer scaffolding against the host's existing configuration.
A successful install is not an automatic merge or permission to replace the host
resolver. Full admin Surface and continuation remain separate work.

## Respect Rails Transaction Semantics

Active Record callbacks can abort a save or request `ActiveRecord::Rollback`.
A swallowed rollback must not produce a successful admin receipt. Conversely,
`after_commit` exceptions occur after the business transaction may already have
committed. The runner checks persistence outcomes and preserves committed receipts
with a separate callback warning rather than reporting them as rolled-back writes.
These were integration hazards in the admin implementation, not established Rails
bugs. Ruby's integer parsing and SQLite's explicit LIKE escape behavior also need
adapter-side handling; the current coercion/query code covers those cases.

## Verify Assistant Storage Isolation Before Integration

RubyLLM 2.1.1 permits custom Chat/Message class mappings. Its released message macro
still maps ToolCall and Usage associations to shared SDK classes/tables, and has
no `tool_call_class` keyword. Host B public reflection confirmed those targets;
the keyword is rejected. Pending approvals also directly query the SDK ToolCall
class. Custom Chat/Message models therefore do not by themselves satisfy this
project's Engine-owned ToolCall storage requirement.

This is a concrete gap in our proposed integration, not a violated RubyLLM promise.
Resolve it with supported released APIs or a reviewed upstream extension before
enabling admin Chat. Do not override SDK global table names, patch private methods
or silently share product tool-call rows. The current conventional admin does not
create admin Chat/ToolCall records and does not claim this proof is complete.

The checkout's `docs/reference/dependency-contracts.md` links the owning released
persistence sources. No provider key or network call was used for the mapping probe.

DEP-001 and DEP-006 are resolved for the selected 1.0.2 package. Remaining storage,
provider and integration evidence must still be established. Keep unconfirmed
findings labelled as such and reproduce them against a released package before
proposing a dependency fix.

## Next Steps

* [Operations]({% link _core_features/operations.md %}) specifies current result semantics.
* [Development Status]({% link _reference/development-status.md %}) lists unsupported integrations.
