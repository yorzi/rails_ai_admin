# Compatibility

Status checked 2026-10-30 (Asia/Shanghai). This is unreleased local evidence.
CI configuration is not a completed CI run; no production support is declared.

| Component / combination | Evidence |
| --- | --- |
| Ruby 4.0.9, Rails 8.1.4, JSON 3.1.0, macOS arm64 | Local core and request suites executed |
| SQLite (`sqlite3` 2.10.2) | 171 tests / 991 assertions, including fixed selections/current-authority manifests, table/key identity guards, collection admission/cancel/worker races, late lease guards, receipt replay, outbox fencing, request fingerprints, schema suggestions, installer preservation and atomic rollback |
| PostgreSQL 17.11 (`pg` 1.7.0), same Ruby/Rails | 171 tests / 991 assertions, including native UUID selections/targets, authorized joins/includes, same-pool delivery checks, collection item/admission/outbox contracts, concurrent cancel/claim and contention and atomic rollback |
| Packaged session / SQLite consumer, Propshaft 1.3.2, host importmap 2.2.3 | Actual `.gem` install, closed generated context, install rerun, schema suggestions with no automatic exposure, login/CSRF/CRUD, native fixed-selection capture/revocation, collection review/queue/results and custom-operation confirmation/replay plus host TestKit matrix (5 tests / 73 assertions), generated anonymous HTTP test (1 / 1), doctor, Zeitwerk, production eager load and precompile |
| Prebuilt Turbo 8.0.23 / Stimulus 3.2.2 | Reproducible esbuild output; Chrome login/list/show/form validation/save checked; nonce CSP without unsafe-inline; 320px and desktop CRUD spot checks; packaged Sprockets Host B custom-operation Turbo Stream review and explicit confirmation checked in Chrome at 500px, with no console/CSP errors; fixed-selection checkbox capture/303/current preview checked in the packaged Sprockets host at 500px with scrolling confined to the table |
| Ruby 3.4 and Linux | CI configured; not executed locally or remotely yet |
| Independent packaged Host B: Devise 5.0.4 / Pundit 2.5.2 / PostgreSQL | Real login/CSRF/logout/timeout, role/tenant grants, UUID replay/selection, independent selection grants, collection partial cancellation, separate parent/item grants and synthetic outbox effects, alias scope, product SDK coexistence and TestKit matrix: 16 tests / 168 assertions; generated anonymous HTTP test (1 / 1). Existing mount in a `draw` route file preserved |
| Host B Propshaft 1.3.2 or Sprockets 4.4.1 / sprockets-rails 3.5.2, jsbundling-rails 1.3.1 | Both production precompiles and eager boots passed; host esbuild 0.25.12 bundle built; each variant passed Host B acceptance. These are two variants of one host |
| Host B development reload and process recovery | Real source reload replaced model/resource/policy/context/Operation/Work classes and registries; killed precommit transaction rolled back domain/claim/audit; response-loss replay returned one receipt. Separate worker processes died before/after synthetic effects: expired-lease idempotent replay applied once, non-idempotent pre-effect retry succeeded, and unknown non-idempotent outcome required reconciliation without resend |
| Real providers / persisted Chat / Surface / continuation | Not implemented or tested; no paid calls |

Runtime bounds: Ruby >= 3.4; Rails >= 8.1.4 and < 8.2; rails_tool_views ~> 1.0.2;
RubyLLM >= 2.1.1 and < 3; turbo-rails ~> 2.0; stimulus-rails ~> 1.3. These bounds
are candidate dependency constraints, not proof every resolvable combination works.
The lockfile records actual resolution, including Linux/source platform metadata.

Published rails_tool_views 1.0.2 package SHA-256:
`3d169601f62005fff6e510b604e377585edc308b31c92a4df6cc21b3a0789d50`.
Host A conventional packaged boot did not load RubyLLM/rails_tool_views constants, create
AI/runtime tables, access provider keys or call a provider. A host already using
both SDKs (Host B) preserved its product Chat/Message, Surface and global settings
through conventional admin CRUD/member/collection operations and development reload. Full admin Chat/Surface and
continuation coexistence still needs separate acceptance. Admin ToolCall/Usage
rows use RubyLLM's shared tables, isolated per chat by polymorphic scoping.

Unsupported in this slice: MySQL, composite keys, multiple/parameterized mounts,
shards, cross-pool atomic writes, global operations, custom CRUD replacement,
10,000-target materialization, a full job/reconciliation center, Chat, Surface
dispatch, associations, private files, imports, exports and dashboards
beyond the resource landing page. Generic writes require `lock_version` and
synchronous database-only callbacks. Member handlers and post-commit Work are
trusted Ruby, with bounded metadata and cooperative checks, not a sandbox or hard
execution timeout. External retry safety requires the downstream to honor the
stable delivery key; tests use a synthetic file-backed receiver, not a real provider.
Policy scopes reject limit/offset/select/
group/having/from rather than risk widening membership. Fixed selections and asynchronous collection admission currently support at most
100 explicit targets. Each item commits independently; pending scans and a persistent
host queue are required. Larger manifests and retention/cleanup remain open.
Host SQL debug logs,
custom instrumentation and callback side effects remain host responsibilities.

The 1.0.2 upgrade changed only rails_tool_views in the resolved dependency graph.
Its actual installer was rerun in Host B without restoring routes; source remained
byte-identical and the named helper retained `/product_surfaces` on both pipelines.
DEP-001 is closed as the documented host-owned shared-runtime contract; DEP-006 is
closed as the concrete installer fix. This does not complete admin Surface isolation.

Collection-specific live-process recovery covered durable claim loss, SIGKILL after
uncommitted target SQL, and death after business/item/audit commit before response.
Fresh workers waited for real five-second fixture leases where necessary; each
target committed once, children had no second approval, and outbox remained separate.
Browser collection review/queue/partial-cancel was checked before the SDK upgrade:
review changed no records, admission consumed one approval and two queued items,
one item committed and cancellation retained it plus its pending Work. Post-upgrade
HTTP acceptance passed. Collection narrow-screen screenshots/DOM sizing were not
completed because automatic approval review hit a usage limit; no visual/responsive
claim is made for that check. The task browser tab and temporary services were closed.

Chrome spot checks are not complete accessibility, browser or responsive
certification. Firefox, Safari, 200% zoom, multilingual/long data and broader
fault injection remain open. Internal model review is not an independent audit.

RubyGems `rails_ai_admin` lookup returned HTTP 404 on 2026-10-29; no name is
reserved and no trademark clearance is claimed. No remote repository, hosted
docs site, deployment, tag or gem publication has been created.

Dependency and docs lockfiles passed bundler-audit against advisory DB commit
`920f5cd5e02cbe598f60afb02f533d608133b795` (1,284 advisories). Frontend installation
reported no npm advisories. These scans are dated evidence, not a security proof.
