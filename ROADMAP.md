# Roadmap

Implementation started 2026-10-29 from the reviewed v0.3 plan. The first conventional
CRUD vertical slice is implemented and locally validated. **No full phase or
release Gate A–E is closed.** The plan remains the complete requirement baseline;
this file records current scope without rewriting its historical review claims.

## Implemented foundation

- Local Git, MIT/open-source policies and coherent milestone commits (RAA-0001,
  local portion; no remote rules/branch protection).
- Isolated Engine, namespaced storage, bounded dependencies, frozen string-name
  configuration and explicit registry (RAA-0101/0103/0106, initial contracts).
- Fresh typed actor/tenant context, default-deny actions/SQL scopes/fields and
  readonly aliases. Custom policy adapter only (parts of RAA-0104/0105).
- Typed scalar fields and conventional index/show/new/edit/create/update/delete;
  separate delete confirmation, validation input preservation, bounded search/sort,
  custom mount and relative URL root (parts of RAA-0201–0207/0210/0212).
- Server-owned intents with input/identity/epoch/version/expiry binding, database
  serialization, replay, atomic domain/audit/receipt, callback rollback handling
  and separate post-commit warning (synchronous parts of RAA-0112/0113).
- Closed install/resource generators, basic doctor and framework-neutral TestKit
  assertions (initial RAA-0108/0109/0115; reflected field suggestions still open).
- Prebuilt namespaced assets, CSP nonce, native forms and dirty-form warning;
  one independent session/SQLite/Propshaft consumer installed from the `.gem`
  (parts of RAA-0110/0114 and SPIKE-01/07).
- Public Jekyll/RDoc/LLM documentation, threat model and initial ADRs. ADRs are
  implementation decisions awaiting owner review, not an approved Gate A.

See COMPATIBILITY.md for exact executed combinations. CI is configured for Ruby
3.4/4.0 and SQLite/PostgreSQL, packaged installation, asset reproducibility,
documentation and advisory scanning. No remote CI run has occurred.

## Next implementation checkpoint

Finish the Phase 1 evidence before broadening conventional features:

1. Add an independent Devise/Pundit/PostgreSQL packaged Host B, followed by
   Sprockets and jsbundling/static-asset consumption. Prove real development reload.
2. Exercise process restart/response-loss recovery and separate-intent contention;
   expand doctor/TestKit and field/schema suggestion diagnostics.
3. Complete async/outbox and the custom Operation contract before exposing custom
   handlers or claiming all of RAA-0112/0113. Generic callbacks with external effects
   remain unsupported; no in-process retry may create a second business intent.
4. Close the initial ADR/threat/requirement traceability and relevant spikes with
   evidence. Add the allowed-failure Rails main prewarning and complete the wider
   CI/security/browser matrices after their prerequisites exist.

## Remaining product work

- Phase 2: complete field/plugin/override, form recovery and three-resource acceptance.
- Early proof: ordinary Order Review and one trusted Surface through the same
  Operation, then an offline released RubyLLM loop and continuation faults.
- Phases 3–4: associations, batch/selection, CSV, private files, audit explorer,
  dashboards and the complete conventional P0 baseline.
- Phases 5–7: isolated persistent Chat, released-SDK integration, quotas, revocation,
  single business approval authority, Surface coexistence and durable continuation.
- Phases 8–9: migration/independent users, broader performance/accessibility and
  security review, packaged RC/restore evidence and explicit release approval.

Provider budget, publication, public deployment and production data use require
the owner's explicit authorization. Competitor hands-on baselines, 20–30 workflow
scripts, three migration samples and independent human validation remain open.
Local success does not substitute for them.
