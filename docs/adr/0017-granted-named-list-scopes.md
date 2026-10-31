# ADR 0017: Named list scopes are granted narrowings of the policy relation

Status: implemented development contract; Phase 2 and release gates remain open.

`Resource.scopes { scope name, body = nil, label: nil, default: false }` declares
named index tabs. Names are lowercase identifiers of 1..40 characters; labels use
the bounded plain-text caption rules of ADR 0016 and default to the humanized
name. A body is nil (the whole authorized relation) or a zero-argument lambda;
Procs, arguments, a second default, duplicates and more than 20 scopes are
configuration errors. Declaration evaluates nothing. Registration freezes the
list, and subclasses start empty, like fields.

The body is trusted host Ruby, so the framework does not rely on it to preserve
authority. It is evaluated on `model.all` under write prevention and must return
a relation of the same model without limit, offset, select, group, having, from
or eager loading. The result is applied as
`policy_relation.where(pk => candidate.unscope(:order).select(pk))`. Rails 7+
`merge` replaces conditions on the same column, so merging a body such as
`where(account_id: other)` could replace the tenant predicate; `and` rejects
structurally different relations. The primary-key semi-join keeps the policy
predicate intact even when the body uses `unscoped`, `or` or another tenant's
condition, and joined bodies cannot duplicate rows. Composite primary keys are
rejected rather than approximated. Body failures become a generic
ConfigurationError without the host message or cause.

A scope predicate can reveal facts about fields the actor cannot read (for
example "missing internal note"), which SEC-017/FAIL-05 treat as inference.
Scopes therefore need an independent default-deny adapter grant,
`named_scopes(context:, resource:)` (Pundit: `permitted_named_scopes`). It is not
derived from index, read, search or sort, and unknown granted names are ignored.
Access returns declared scopes in declaration order intersected with that grant.
The framework cannot prove that a body reads only the fields the host meant; the
grant is the host's statement about who may learn each predicate.

`Queries::List#call(scope:)` is strict: nil applies the declared default only when
it is currently granted, otherwise the policy relation; a named scope must be
declared and granted or INVALID_QUERY results. Page reports the applied name.
Search, sort, pagination and empty-page recovery all run on the scoped relation.
There are no record-count badges (LIST-018 large-table counting stays open).

List hints add a fifth key, `scope`. Strict index requests reject malformed or
undeclared names with 422. A declared but revoked scope is discarded with the
existing notice and page reset. The currently granted default is omitted from the
canonical hint, so default and no-parameter URLs are identical. Hints remain
excluded from intent, Selection and receipt identity.

The index renders a labelled `nav.raa-scopes` of current grants with
`aria-current="true"` on the applied scope, preserving search/sort and resetting
page. The search form carries the scope. resource_index advances to revision 3
with `list_scopes` and `current_scope` assigns. TestKit adds
`named_scope_grants`/`assert_named_scopes`.

Contract and request tests cover declaration bounds, laziness, default-deny
grants, intersections against `unscoped`/`or`/foreign-tenant/joined/model-scope
bodies, rejected shapes, generic failures, prevented writes, hint
canonicalization/revocation and rendered navigation on SQLite and PostgreSQL.
Host A grants Order tabs by role with a default and observes a renamed label after
real reload. Host B grants Pundit tabs without a default, and its note-derived tab
follows the internal_note read grant. A Chromium check of Host A at 1280px and
320px found 44px targets, no page overflow, keyboard Tab/Enter switching and no
console or CSP errors. No screen-reader check was made.

This completes the named-scope part of RAA-0201. Typed resource filters and the
Phase 3 Filter AST (RAA-0302), saved views and scope counts remain open.
