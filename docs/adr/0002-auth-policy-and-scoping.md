# ADR 0002: Host context, explicit policy and default deny

Status: implementation decision, owner review pending.

A context adapter exposes `resolve(controller)` and returns `Context` or nil.
It uses public host session/authentication interfaces. Nil gives a generic 401.
No adapter means no access. The policy adapter defaults to an empty SQL scope,
false actions and empty field lists. No permission follows merely from login.

Policies implement `scope`, `allowed?` and `fields` using documented keyword
arguments. Scopes must be complete SQL relations of the resource model; pages
cannot filter unauthorized rows after pagination. Record actions are rechecked.
Read, write, search and sort field grants are separate, intersected with the DSL.
An alias has its own policy and key. Labels require a readable declared title.
Unknown resources and forbidden records return the same 404.

Context contains typed actor/tenant references and an explicit security version.
The host increments this version for session/role/tenant authority changes.
Requests and retries reconstruct authority; old receipts do not grant access.
Trusted host Ruby can bypass these APIs; extensions are not a sandbox.

## Optional Pundit mapping

The host can install `pundit >= 2.5, < 3` and select
`RailsAiAdmin::Authorization::PunditAdapter`. Each resource explicitly declares
`policy "TicketPolicy"`. Resolve the named class afresh; do not infer a model
policy or merge authority for two resources sharing a model. Policy construction
receives the complete admin `Context` as its first argument and a record/model
as its second, rather than a bare user.

The supported predicates are `index?`, `show?`, `create?`, `update?` and `destroy?`.
Separate `readable_fields`, `writable_fields`, `searchable_fields` and
`sortable_fields` methods supply grants. Missing policies, action predicates and
field methods grant nothing; do not infer field grants from Pundit
`permitted_attributes`. Normal Pundit denials return false. Unexpected policy
errors are surfaced as generic `ConfigurationError` without retaining exception
text/cause.

The SQL Scope must be defined by the mapped policy or explicitly inherited from
a parent policy class. Never accept an unrelated `Object::Scope`. Its
`initialize(context, relation)` and `resolve` contract must return a complete
filter relation of the resource model. Limits, offsets, selects, groups, having
and custom from clauses are rejected by the shared access layer. Doctor can
report mapping metadata; a complete mapping does not prove authorization.

## Host Devise session boundary

The independent packaged support host uses Devise/Warden for authentication,
reloads the actor from its table and resolves the selected tenant through verified
memberships. This keeps cached session actors and unverified submitted tenant IDs
from becoming authority. Devise timeout/logout behavior remains host-owned. No
accounts, roles or login/logout routes are added by the admin engine.

The host separately owns product RubyLLM chats and rails_tool_views Surfaces.
Conventional admin activity preserves that SDK configuration/ownership; full admin
Surface and continuation coexistence remains unresolved. No provider is invoked
by these fixture checks. These limited consumer results do not close a full
architecture, AI or release gate.

The operation fingerprint includes the explicit policy mapping. Existing
development form/proposal intents are invalidated when this mapping changes;
users reopen forms and review current authority. Runtime policy and field checks
remain mandatory regardless of fingerprint equality.
