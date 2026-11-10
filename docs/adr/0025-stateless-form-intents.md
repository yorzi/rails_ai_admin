# ADR 0025: Native form pages issue signed form references, not intent rows

Status: implemented development contract. Amends ADR 0013 (form recovery) and the
intent lifecycle in ADR 0003.

## Context

`GET …/new`, `…/edit` and `…/confirm_destroy` called `Runner#prepare`, which
inserted a `proposed` `OperationRun` on every page view. Turbo 8 prefetches a
link on hover, so moving the pointer over "New record" wrote a row each time
(audit finding RAA-005: three hovers, three rows). GET was not safe for read
replicas, crawlers or link scanners, and nothing removed the abandoned rows: the
audit demo held 51 abandoned `proposed` CRUD intents next to 35 succeeded runs.

The layout now disables Turbo prefetch, but that only removes one trigger.

## Decision

1. A native form page runs the same checks `prepare` ran (current Context,
   action grant, target in scope, expected `lock_version`, resource/operation
   fingerprint) and writes nothing. It renders a **form reference**: a payload
   signed with `Rails.application.message_verifier("rails_ai_admin/form_intent")`
   that names the future run's UUID, owner, tenant, security epoch, resource,
   operation fingerprint, target, expected version, `created_at` and `expires_at`.
   The signature lifetime is the one-hour recovery window.
2. The first submit materializes the reference into a `proposed` run with exactly
   those values (`Runner#materialize_form_intent`), committed on its own, then the
   unchanged `Runner#execute` runs. A rejected submit therefore leaves the same
   proposed intent for the next attempt, as before. A second submit of the same
   form finds the row and replays its receipt. Concurrent first submits converge
   on the primary key.
3. A reference that does not verify, has expired its signature, or names another
   actor or tenant materializes nothing and is `NOT_FOUND`. The reference is not
   authority: every check in `execute` still applies, including the epoch it
   carries, so a form opened before a security-version change is still
   `APPROVAL_INVALIDATED` unless recovery renewed it.
4. Form recovery (ADR 0013) accepts the reference in
   `X-RailsAiAdmin-Recovery-Intent`. For an unsubmitted create/update reference
   it materializes the run first, then applies the existing locked checks and
   renews the same run's epoch and expiry. The form keeps the original reference,
   so the client's same-intent comparison is unchanged. Delete and custom
   operation forms remain outside recovery.
5. `Runner#prepare` and `preflight` keep creating rows for programmatic callers,
   custom operation reviews and assistant proposals; those flows start from POST
   or a trusted adapter, not a page view.
6. `rails_ai_admin:prune` deletes proposed root intents and selections whose
   expiry passed more than `DAYS` days ago (default 7). It never deletes a run
   that started, succeeded, has children, batch or work rows, or a selection a
   run still references. Audit events are never pruned here (ADR 0005).

## Consequences

* Page views, prefetches and link scanners no longer write.
* The form reference is signed, not encrypted. Its fields are references the
  holder already has; `intent_ref` stays in the filtered parameter list.
* Rotating `secret_key_base` invalidates open forms, as it invalidates sessions.
* A host test that looked up `OperationRun.find(form_value)` must use
  `RailsAiAdmin::Operations::FormIntent.id_for(form_value)`, and a run exists only
  after a submit or recovery.
