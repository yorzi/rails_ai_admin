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

## Share RubyLLM's Tool Call and Usage Tables

RubyLLM 2.1.1 permits custom Chat/Message class mappings. Its released message macro
maps ToolCall and Usage associations to RubyLLM's own `ruby_llm_tool_calls` and
`ruby_llm_usages` tables, and has no `tool_call_class` keyword. RubyLLM owns those
supporting tables while applications own chats and messages, so admin Chat uses
Engine-owned Chat/Message tables and shares the ToolCall/Usage tables.

Rows stay isolated per chat. The associations are polymorphic, and chat-level
lookups such as pending approvals filter by the message class and the chat's own
message ids. A probe with admin and product chats sharing the same ids kept their
tool calls, pending approvals and usages apart and rejected a cross-chat approval.
Read these rows only through the admin's own associations. Do not override SDK
table names or patch private methods. The usage ledger is shared, so choose the
admin's usage owner deliberately to keep admin spend out of product totals.

The checkout's `docs/reference/dependency-contracts.md` links the owning released
persistence sources. No provider key or network call was used for the probes.

DEP-001 closes against the documented rails_tool_views 1.0.2 runtime contract;
DEP-006 is its released installer fix. DEP-007 is the accepted RubyLLM 2.1.1
storage-ownership decision, not a rails_tool_views version fix. Remaining storage,
provider and integration evidence must still be established. Keep unconfirmed
findings labelled as such and reproduce them against a released package before
proposing a dependency fix.

## Open Integration Findings

Integrating the admin review Surface with rails_tool_views 1.0.2 surfaced five
gaps, all worked around through public APIs and covered by tests:

* DEP-008: `reset_registry!` removes every gem's components and there is no
  registered/replace API; the admin re-registers a constant contract lazily.
* DEP-009: policies and handlers cannot receive request-scoped host authority;
  admin endpoints bind the admin Context for one call.
* DEP-010: the action-form helper has no `url:` option; the admin reuses
  `rails_tool_views_action_fields` with its own endpoint.
* DEP-011: there is no public lookup of a correlated presentation; assistant
  proposals derive one deterministic intent per tool call.
* DEP-012: `RailsToolViews.render` needs `SurfacesHelper` in the calling view;
  the admin extends only the rendering view.

The checkout's `docs/reference/dependency-contracts.md` lists each workaround and
the suggested backward-compatible upstream change. None has been filed upstream.

## Isolate Rails Route Probes

Rails 8.1.4 shares mounted-helper definitions between route sets. A fake route set
mounting a live Engine before real lazy routes are drawn can capture its fake
prefix. Installer probes draw the actual host first and isolate the Engine route
set used by scratch applications, without mutating Rails private helper modules.
This is a test/integration constraint, not an established upstream defect or a
claim of support for independent hosts/mounts in one process. The supported
integration uses one named host mount.

## Next Steps

* [Operations]({% link _core_features/operations.md %}) specifies current result semantics.
* [Development Status]({% link _reference/development-status.md %}) lists unsupported integrations.
