# Compatibility

Status checked 2026-10-29 (Asia/Shanghai). This is unreleased local evidence.
CI configuration is not a completed CI run; no production support is declared.

| Component / combination | Evidence |
| --- | --- |
| Ruby 4.0.9, Rails 8.1.4, JSON 3.1.0, macOS arm64 | Local core and request suites executed |
| SQLite (`sqlite3` 2.10.2) | 56 tests / 276 assertions, including contention, atomic rollback, UUID refs and cross-pool rejection |
| PostgreSQL 17.11 (`pg` 1.7.0), same Ruby/Rails | 56 tests / 276 assertions, including native UUID targets, contention and rollback |
| Packaged session / SQLite consumer, Propshaft 1.3.2, host importmap 2.2.3 | Actual `.gem` install, closed generated context, install rerun, readonly resource generator, real login/CSRF/CRUD/replay (27 assertions), doctor, Zeitwerk, production eager load and precompile |
| Prebuilt Turbo 8.0.23 / Stimulus 3.2.2 | Reproducible esbuild output; Chrome login/list/show/form validation/save checked; nonce CSP without unsafe-inline; 320px and desktop spot checks |
| Ruby 3.4 and Linux | CI configured; not executed locally or remotely yet |
| Sprockets / jsbundling consumers | Not yet validated |
| Devise / Pundit packaged Host B | Not implemented yet; custom policy adapter is the only executed host integration |
| Real providers / persisted Chat / Surface / continuation | Not implemented or tested; no paid calls |

Runtime bounds: Ruby >= 3.4; Rails >= 8.1.4 and < 8.2; rails_tool_views ~> 1.0.1;
RubyLLM >= 2.1.1 and < 3; turbo-rails ~> 2.0; stimulus-rails ~> 1.3. These bounds
are candidate dependency constraints, not proof every resolvable combination works.
The lockfile records actual resolution, including Linux/source platform metadata.

Published rails_tool_views 1.0.1 package SHA-256:
`b35d792611e46e55b1be1b79898fab39445bebc7583d7e1e67ae7229468ada1e`.
Conventional packaged boot did not load RubyLLM/rails_tool_views constants, create
AI/runtime tables, access provider keys or call a provider. A host already using
both SDKs still needs separate coexistence acceptance.

Unsupported in this slice: MySQL, composite keys, multiple/parameterized mounts,
shards, cross-pool atomic writes, custom operation handlers, async/outbox, Chat,
Surface dispatch, associations, private files, imports, exports and dashboards
beyond the resource landing page. Generic writes require `lock_version` and
synchronous database-only callbacks. Policy scopes reject limit/offset/select/
group/having/from rather than risk widening membership. Host SQL debug logs,
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
