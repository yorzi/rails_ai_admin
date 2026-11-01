# ADR 0020: Admin review Surfaces share native intents through admin-owned endpoints

Status: implemented development contract (narrow early proof); Phase 2.5/6 and
release gates remain open. Partially supersedes ADR 0004's "no Surface write
routes" boundary for this opt-in only.

## Context

The product hypothesis is a persistent, Rails-native interactive Surface over the
same deterministic domain Operation, not a second execution path (plan §1.2,
§6.3). rails_tool_views 1.0.2 has one process-wide configuration: scope
resolver, parent controller, agent adapter, auto_deliver and component registry.
Its action helper always posts to the engine mounted as `rails_tool_views`, which
authenticates through the host's global resolver. An admin integration that
configured those globals would break a host that already uses rails_tool_views
for its product (plan §6.3.1, SPIKE-06).

## Decision

`config.surfaces = true` opts in. It requires that the host already load
rails_tool_views and install its tables. Conventional hosts load no integration
code and draw no Surface routes; Host A asserts both, plus that no
rails_tool_views constant exists after production eager loading. The admin never
reads or writes the host's resolver, parent controller, agent adapter or
auto_deliver, and never resets the host registry. Member operations opt in with
`operation ..., surface: true`. The flag is not part of operation identity and
grants nothing.

Admin-owned endpoints live under the reserved `assistant` path:
`POST :resource/:id/operations/:operation/surface`, `GET assistant/surfaces/:id`
and `POST assistant/surfaces/:id/actions`. They inherit fresh admin
authentication, CSRF and log filtering. They call the public
`present/restore/dispatch/render` API with an explicit
`Scope(actor: context.actor_ref, tenant: context.tenant_ref)`; those refs are
already `raa:actor:<Class>:<id>` and `raa:tenant:<Class>:<id>`. The admin action
form reuses `rails_tool_views_action_fields` but posts to the admin endpoint.
This is the plan's shared mode. A separate exclusive mode is unnecessary because
nothing depends on host globals.

There is one component, `raa_operation_review`. Its props are only the intent UUID
and the canonical wire input string, so its schema, renderer and action contract
(and therefore its digest) are constant across host reloads. rails_tool_views has
no unregister API, and host `to_prepare` hooks may run `reset_registry!` after
the engine's. The integration therefore registers lazily and idempotently before
every use. An existing registration must carry the admin's own policy and
handler objects, otherwise it is a configuration error (squatting). The
component is not exposed to agents yet (`expose_to: []`).

Policy and handler deny unless the current admin Context is bound for the call
(`ActiveSupport::IsolatedExecutionState`, set by an around_action) and matches the
Scope exactly. A host resolver or caller that produces an admin-shaped scope
outside admin endpoints is therefore denied (NOT_ALLOWED). Product scopes never
match (NOT_FOUND), and admin endpoints cannot open product Surfaces. Each policy
call re-resolves the intent by id, actor and tenant (byte-exact) and the current
record through the policy scope and show grant. Presentation requires an
unconsumed native intent, its security version, its expiry and the presented
input's digest; it replays the same Surface per intent through a correlation
key. Reading a completed review is a receipt read and needs the independent
receipt grant, like native replay. The recorded input is displayed through the
operation's declared contract, because a command grant may lapse once the
business precondition changes (found in Host B).

Confirm is the human's own CSRF-protected Surface form submission. It calls the
shared Runner with the same intent, `human_confirmed: true` and `origin:
surface`, inside rails_tool_views' Surface lock. The Runner's
`requires_new` transaction becomes a savepoint, so the business write, audit,
receipt, outbox Work, Surface revision and ActionExecution commit or roll back
together. Whichever channel confirms first writes once; the other replays the
receipt. Business rejections (CONFLICT, APPROVAL_EXPIRED/INVALIDATED,
VALIDATION_FAILED, IDEMPOTENCY_CONFLICT) are committed as a Surface transition
with their failure audit. Operation failures raise, roll everything back
(including that failure audit), keep the revision and intent unchanged, and stay
retryable. Lost authority raises NOT_ALLOWED and records nothing. Same-key
retries replay rails_tool_views' ActionExecution without running the handler.

The native confirmation page offers the hand-off through a separate form, because
Rails per-form CSRF tokens bind a token to its action URL. Host B rejected the
first, `formaction`-based version with 422, which the CSRF-free engine dummy app
could not reveal.

## Evidence

Engine request tests (CSRF disabled) cover presentation, rendering, both
confirmation orders, same-key and cross-channel replay, stale revisions,
security-version revocation, a changed record, operation failure rollback and
retry, foreign actors, unbound and product scopes, lapsed input/receipt grants,
Turbo Stream replacement, re-registration after reset, squatting, the opt-in and
Doctor. They run on SQLite and PostgreSQL with no global rails_tool_views
configuration at all. Packaged Host B (Devise, Pundit, PostgreSQL, real per-form
CSRF, its own `host_notice` product Surface and resolver) confirms a triage
intent through the admin Surface. In that run the product mount cannot restore
it, an admin-shaped scope outside admin endpoints is denied, and the native page
replays with one outbox item. The host resolver, auto_deliver and component are
unchanged, on both asset pipelines, and its development reload probe
re-registers the admin component after the host reset. A Chromium check of Host
B at 1280px and 320px covered the full flow with keyboard confirmation via Turbo
Stream, reload persistence and no console, CSP or HTTP errors.

## Not decided or not done

There is no assistant presentation (PresentUI), agent continuation or
`deliver`, no RubyLLM chat, and no edit-in-Surface input. Surface templates are
outside the override catalog, and Surface retention/close is not wired up.
SPIKE-02/03 remain open. Only Host B carries a product Surface: Host A must stay
the AI-free baseline. That deviates from the plan's two-host SPIKE-06 wording and
from its Order example; the proof uses Host B's ticket triage operation. The
upstream helper option for a custom action URL (plan §6.3.1 item 5) was not
needed and was not requested.
