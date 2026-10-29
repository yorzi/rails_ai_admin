# Compatibility

Status checked 2026-10-30 (Asia/Shanghai). This is unreleased local evidence.
CI configuration is not a completed CI run; no production support is declared.

| Component / combination | Evidence |
| --- | --- |
| Ruby 4.0.9, Rails 8.1.4, JSON 3.1.0, macOS arm64 | Local core and request suites executed |
| SQLite (`sqlite3` 2.10.2) | 138 tests / 750 assertions, including fixed selections/current-authority manifests, table/key identity guards, pure operation previews, receipt replay, outbox fencing, request fingerprints, schema suggestions, installer preservation and atomic rollback |
| PostgreSQL 17.11 (`pg` 1.7.0), same Ruby/Rails | 138 tests / 750 assertions, including native UUID selections/targets, authorized joins/includes, same-pool delivery checks, operation/outbox contracts, contention and atomic rollback |
| Packaged session / SQLite consumer, Propshaft 1.3.2, host importmap 2.2.3 | Actual `.gem` install, closed generated context, install rerun, schema suggestions with no automatic exposure, login/CSRF/CRUD, native fixed-selection capture/revocation, custom-operation confirmation/replay plus host TestKit matrix (4 tests / 58 assertions), generated anonymous HTTP test (1 / 1), doctor, Zeitwerk, production eager load and precompile |
| Prebuilt Turbo 8.0.23 / Stimulus 3.2.2 | Reproducible esbuild output; Chrome login/list/show/form validation/save checked; nonce CSP without unsafe-inline; 320px and desktop CRUD spot checks; packaged Sprockets Host B custom-operation Turbo Stream review and explicit confirmation checked in Chrome at 500px, with no console/CSP errors; fixed-selection checkbox capture/303/current preview checked in the packaged Sprockets host at 500px with scrolling confined to the table |
| Ruby 3.4 and Linux | CI configured; not executed locally or remotely yet |
| Independent packaged Host B: Devise 5.0.4 / Pundit 2.5.2 / PostgreSQL | Real login/CSRF/logout/timeout, role/tenant grants, UUID replay/selection, independent selection grants, custom-operation grants/receipts, synthetic outbox effects, alias scope, product SDK coexistence and TestKit matrix: 15 tests / 149 assertions; generated anonymous HTTP test (1 / 1). Existing mount in a `draw` route file preserved |
| Host B Propshaft 1.3.2 or Sprockets 4.4.1 / sprockets-rails 3.5.2, jsbundling-rails 1.3.1 | Both production precompiles and eager boots passed; host esbuild 0.25.12 bundle built; each variant passed Host B acceptance. These are two variants of one host |
| Host B development reload and process recovery | Real source reload replaced model/resource/policy/context/Operation/Work classes and registries; killed precommit transaction rolled back domain/claim/audit; response-loss replay returned one receipt. Separate worker processes died before/after synthetic effects: expired-lease idempotent replay applied once, non-idempotent pre-effect retry succeeded, and unknown non-idempotent outcome required reconciliation without resend |
| Real providers / persisted Chat / Surface / continuation | Not implemented or tested; no paid calls |

Runtime bounds: Ruby >= 3.4; Rails >= 8.1.4 and < 8.2; rails_tool_views ~> 1.0.1;
RubyLLM >= 2.1.1 and < 3; turbo-rails ~> 2.0; stimulus-rails ~> 1.3. These bounds
are candidate dependency constraints, not proof every resolvable combination works.
The lockfile records actual resolution, including Linux/source platform metadata.

Published rails_tool_views 1.0.1 package SHA-256:
`b35d792611e46e55b1be1b79898fab39445bebc7583d7e1e67ae7229468ada1e`.
Host A conventional packaged boot did not load RubyLLM/rails_tool_views constants, create
AI/runtime tables, access provider keys or call a provider. A host already using
both SDKs (Host B) preserved its product Chat/Message, Surface and global settings
through conventional admin CRUD/member operations and development reload. Full admin Chat/Surface and
continuation coexistence still needs separate acceptance. Released SDK ToolCall
storage is shared by default; Engine-owned ToolCall storage is unresolved.

Unsupported in this slice: MySQL, composite keys, multiple/parameterized mounts,
shards, cross-pool atomic writes, collection/global operations, custom CRUD
replacement, asynchronous business execution, a full job center, Chat, Surface
dispatch, associations, private files, imports, exports and dashboards
beyond the resource landing page. Generic writes require `lock_version` and
synchronous database-only callbacks. Member handlers and post-commit Work are
trusted Ruby, with bounded metadata and cooperative checks, not a sandbox or hard
execution timeout. External retry safety requires the downstream to honor the
stable delivery key; tests use a synthetic file-backed receiver, not a real provider.
Policy scopes reject limit/offset/select/
group/having/from rather than risk widening membership. Fixed selections currently support explicit capture/preview only, at most 100
targets; no collection admission or 10,000-item async materialization is supplied.
Host SQL debug logs,
custom instrumentation and callback side effects remain host responsibilities.

Chrome spot checks are not complete accessibility, browser or responsive
certification. Firefox, Safari, 200% zoom, multilingual/long data and broader
fault injection remain open. Internal model review is not an independent audit.

RubyGems `rails_ai_admin` lookup returned HTTP 404 on 2026-10-29; no name is
reserved and no trademark clearance is claimed. No remote repository, hosted
docs site, deployment, tag or gem publication has been created.

Dependency and docs lockfiles passed bundler-audit against advisory DB commit
`920f5cd5e02cbe598f60afb02f533d608133b795` (1,284 advisories). Frontend installation
reported no npm advisories. These scans are dated evidence, not a security proof.
