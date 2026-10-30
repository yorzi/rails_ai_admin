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
  readonly aliases. Custom adapter and optional explicit Pundit resource policies
  (parts of RAA-0104/0105).
- Typed scalar fields and conventional index/show/new/edit/create/update/delete;
  separate delete confirmation, validation input preservation, bounded search/sort,
  custom mount and relative URL root (parts of RAA-0201–0207/0210/0212).
- Reloadable scalar field-type registration, immutable descriptors, pure/idempotent
  normalization, typed validation, intersected wire schemas and escaped formatting.
  Form/index/show partials receive authorized scalars; record-specific denied fields
  do not invoke a renderer. Fixed Select labels and readonly shorthand are covered
  in contracts and both packaged hosts. This advances RAA-0203/0208; broader
  override/plugin compatibility remains open.
- Readonly virtual fields with named computations, bounded acyclic declared
  dependencies, recursive current read grants and immutable scalar snapshots.
  Projections cache shared dependencies once; physical getters and computation
  prevent ordinary AR writes. Pure hooks remain trusted Ruby. Current formatted
  titles agree across pages/selections/jobs, virtual input/query targets are
  rejected and fake virtual preflight changes are excluded. Actual packaged
  summaries and source reload advance the Field Registry/CRUD-008 contracts.
- Individual template override generator with 23 explicit current paths/context
  contracts, source/context metadata, preservation of existing edits and bounded
  doctor upgrade diagnostics. New/edit failure wrappers and field defaults obey
  Rails precedence. Packaged Host A rendered every catalogued host override;
  Host B verified its subset on both pipelines and actual template reload.
  This advances RAA-0209/0211; Surface/status/controller extensions remain open.
- Per-view output flags, global hidden resource fields and optional current view
  permission masks applied before recursive computation dependencies. Generic
  Runner writes also enforce create/edit masks. Authorized readonly form context,
  scalar-only grouped form plans, plain help text and progressive tabs preserve
  writable-only legacy assigns. Native errors link to visible editable inputs;
  Chrome checks cover hidden invalid controls, keyboard focus, FormData and 422
  input retention (parts of RAA-0204/0208/0210/0212; ADR 0012).
- Server-owned intents with input/identity/epoch/version/expiry binding, database
  serialization, replay, atomic domain/audit/receipt, callback rollback handling
  and separate post-commit warning (synchronous parts of RAA-0112/0113).
- Explicit Operation registry/default CRUD handlers and member domain handlers,
  typed pure preflight, HTML/Turbo confirmation, separate input/receipt permissions
  and version-advancing custom writes. Host Ruby remains trusted code.
- Atomic post-commit outbox with typed bounded payloads, independent fresh job
  authority, deadlines, request fingerprints, stable delivery keys, finite leases
  and fencing generations. Unknown non-idempotent effects require reconciliation;
  pending scans recover queue loss. These are follow-up effects, not asynchronous
  business execution or a complete job center (further RAA-0112/0113 evidence).
- Fixed Selection manifests with canonical ID/version membership, owner/tenant/
  epoch/expiry and stable model/table/key fingerprints. Native capture/preview,
  independent selection grants and current-authority revalidation are implemented.
  Bounded collection Operations now consume one parent approval, admit durable
  child work and execute each target through the shared Runner with leases,
  current class/record grants, cancellation and safe job views. Real claim-loss,
  precommit-death and postcommit-response-loss probes recover without duplicate
  business writes (initial portions of RAA-0305/0306/0312/0401).
- Closed install/resource generators with an unregistered example, default-deny
  policy and runnable anonymous test. Resource schema suggestions remain comments;
  sensitive/encrypted/relationship/internal fields are omitted. Install checks
  actual final mount names, drawn routes and constant conflicts before writing.
- Doctor metadata checks for adapter interfaces/signatures, scalar schema/type
  compatibility, sensitivity, sortable indexes and default autoloading. TestKit
  covers anonymous adapters, policy matrices, tenant exclusion and independent
  field-grant snapshots in both packaged hosts (initial RAA-0108/0109/0115).
- Prebuilt namespaced assets, CSP nonce, native forms and dirty-form warning;
  two independent consumers installed from the `.gem`: native session/SQLite and
  Devise/Pundit/PostgreSQL, including Propshaft/importmap and Sprockets/jsbundling
  combinations (parts of RAA-0110/0114 and SPIKE-01/07).
- Actual development reload, separate-intent version contention, process death
  before commit and response loss after commit. Host B verifies fresh role/tenant
  membership, logout/timeout and preliminary product SDK coexistence. These do
  not establish admin Chat/Surface or full browser matrix acceptance.
- Public Jekyll/RDoc/LLM documentation, threat model and initial ADRs. ADRs are
  implementation decisions awaiting owner review, not an approved Gate A.

See COMPATIBILITY.md for exact executed combinations. CI is configured for Ruby
3.4/4.0 and SQLite/PostgreSQL, packaged installation, asset reproducibility,
documentation and advisory scanning. No remote CI run has occurred.

## Next implementation checkpoint

Finish the remaining Phase 2 contracts: form/session recovery, remaining status/controller extension points and three
distinct domain-resource acceptance. Scalar/computed fields and the conventional
template override workflow and per-view grouped forms have local evidence; Phase 2 and release gates remain open.

Continue the shared execution contracts while the full Phase 1 evidence remains open:

1. Extend the shared Operation contract to global actions and custom CRUD
   replacement. Complete 10,000-target async manifest materialization, broader
   batch/job workflows and retention beyond the implemented 100-target leased
   collection path. Keep reconciliation and downstream guarantees distinct.
   External effects in domain callbacks remain unsupported; recovery reuses the
   same admitted intent rather than creating another approval.
2. Finish the asset/browser/CSP matrix beyond the existing Host A Chrome spot
   checks, layout/theme tokens and configurable host paths. Later TestKit and
   doctor expansions must cover each new surface; AI exposure reports are open.
3. Close the initial ADR/threat/requirement traceability and relevant spikes with
   evidence. Add the allowed-failure Rails main prewarning and complete the wider
   CI/security/browser matrices after their prerequisites exist.
4. Continue the documented rails_tool_views 1.0.2 host-owned shared-runtime
   integration; DEP-001/006 are closed, while admin Surface acceptance is open.
   DEP-007 is closed: admin Chat uses Engine-owned Chat/Message tables and
   RubyLLM's shared ToolCall/Usage tables, isolated per chat. Admin Chat still
   needs its own contract test for that isolation once it exists.

## Remaining product work

- Phase 2: finish field presentation controls, remaining status/controller
  extension points, form/session recovery and three-resource acceptance.
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
