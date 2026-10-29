---
layout: default
title: Dependency Contracts
nav_order: 4
description: Separate published dependency guarantees from unimplemented admin integration.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* Which released dependency lines the gem selects.
* Why Surface coexistence remains unresolved.
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

## Respect Rails Transaction Semantics

Active Record callbacks can abort a save or request `ActiveRecord::Rollback`.
A swallowed rollback must not produce a successful admin receipt. Conversely,
`after_commit` exceptions occur after the business transaction may already have
committed. The runner checks persistence outcomes and preserves committed receipts
with a separate callback warning rather than reporting them as rolled-back writes.
These were integration hazards in the admin implementation, not established Rails
bugs. Ruby's integer parsing and SQLite's explicit LIKE escape behavior also need
adapter-side handling; the current coercion/query code covers those cases.

No newly confirmed upstream gem defect is established by these observations.
Unconfirmed findings should remain labelled as such, with a minimal reproduction
against a released package before proposing a dependency fix.

## Next Steps

* [Operations]({% link _core_features/operations.md %}) specifies current result semantics.
* [Development Status]({% link _reference/development-status.md %}) lists unsupported integrations.
