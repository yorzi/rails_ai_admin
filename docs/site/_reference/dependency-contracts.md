---
layout: default
title: Dependency Contracts
nav_order: 4
description: Understand selected dependency guarantees, a known installer defect and integration limits.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* Which released dependency lines the gem selects.
* Why Surface coexistence remains unresolved.
* How to preserve a custom mount when running the released Surface installer.
* How Rails callback semantics affect operation results.

## Use Released Dependency Lines

The gem currently bounds Rails to 8.1.4 through below 8.2, `rails_tool_views` to
1.0.1 through below 1.1, RubyLLM to 2.1.1 through below 3, `turbo-rails` to 2.x and
`stimulus-rails` to 1.x. Refer to the lockfile for the exact resolved graph. A
candidate range does not prove all future versions in that range are compatible.

Conventional installation does not provision assistant tables or configure a
provider. No paid provider call is part of default development tests. RubyLLM main
APIs such as unreleased queue/claim/approval primitives must not be assumed present
in the selected released package.

## Keep Surface Coexistence Explicit

The published `rails_tool_views` 1.0.1 package has process-level configuration and
registry objects. Its `scope_resolver`, `parent_controller`, `agent_adapter` and
`auto_deliver` settings are shared by uses in the same process. Its generated action
forms target its own engine routes. Overwriting those values for admin could break
or change authority for a host's existing product Surface.

This is a confirmed integration constraint, not evidence of an upstream defect.
The current admin does not configure those globals or implement Surface actions.
Shared/exclusive routing, identity prefixes and continuation require the planned
SPIKE-03/06 evidence before a support claim. The dependency's stable core does not
make its experimental RubyLLM adapter or this admin's future integration stable.

## Preserve a Custom Surface Mount During Installation

The released `rails_tool_views` 1.0.1 installer has a reproduced custom-mount
limitation: running its install generator when the host already has a custom
mount named `rails_tool_views` adds the default mount with the same route name.
The next route load then fails because the alias is duplicated. This is an
installer defect in that selected release, separate from the process-wide
configuration constraint above.

Install the SDK before customizing its mount where possible. When running its
installer in an existing host, preserve the reviewed host route/configuration and
ensure only one `rails_tool_views` mount alias remains before booting again. Do
not replace an existing product resolver merely to make the install command pass.
The packaged support bootstrap restores its reviewed custom routes after exercising
the released installer; it does not patch dependency source. Full admin Surface
and continuation coexistence still needs its separate proof.

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

The custom-mount installer defect above is reproduced in the selected released
package. The other items remain documented integration constraints and hazards.
Keep unconfirmed findings labelled as such and reproduce them against a released
package before proposing a dependency fix.

## Next Steps

* [Operations]({% link _core_features/operations.md %}) specifies current result semantics.
* [Development Status]({% link _reference/development-status.md %}) lists unsupported integrations.
