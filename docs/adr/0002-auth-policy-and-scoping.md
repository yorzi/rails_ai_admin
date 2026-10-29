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
