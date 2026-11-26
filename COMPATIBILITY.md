# Compatibility

## 2026-11-26 — 0.9.0 development candidate

On Ruby 4.0.10 and Rails 8.1.4.1, the full engine suite exercised SQLite and PostgreSQL 17. The offline Chromium demo saved a live chat chart to Overview, routed a fixed collection to a second reviewer, tracked 125 imported rows through Tasks and checked tenant and drawer context isolation. Recipe tests covered both New York DST transitions, event replay, owner revocation, fixed selection approval and isolated RubyLLM usage. The provider used for the demo and new recipe budget tests was scripted.

All 33 stored OpenRouter evaluation scenarios now pass offline grading. The earlier inactive-customer miss returned the correct count of four by grouping on the active flag. The grader now accepts either the exact filtered count or the exact grouped count with the expected buckets. The historical grades below show the original evaluation criteria.

## 2026-11-26 — 0.8 development recordings

Not a release candidate record. On Ruby 4.0.10 with Rails 8.1.4.1, RubyLLM 2.2.3 and the unchanged prompt version 4, new OpenRouter recordings cover the 0.8 assistant features. Only the cassettes named here were recorded again.

| Check | Executed result |
| --- | --- |
| Relation filter schema | The relation scenario was recorded again so the tool definitions carry the 0.8 `relation_filters` schema (`oneOf`, `patternProperties`, `minProperties`). OpenRouter accepted it for `openai/gpt-6-luna`, `anthropic/claude-haiku-5.5` and `google/gemini-3.8-flash`; all three answered INV-3 and INV-4 only. GPT-6 Luna and Claude Haiku used `relation_filters`; Gemini searched customers by points and then listed invoices |
| Evaluation set | 33 questions. GPT-6 Luna answered the three new ones correctly: `relation_filters: {invoices: {_exists: false}}` for active customers without invoices, one `aggregate_records` cross-tab with `period_field` for monthly counts by status, and `list_quality_rules` then `run_quality_rule`. The named-customer invoices were found with a customer search and an invoice filter, not `_query`. 32 of 33 pass; `count-inactive` stays the recorded miss |
| Cost | About US$0.03 for all new recordings |

## 2026-11-25 — 0.6.0 development recordings

Not a release candidate record. On Ruby 4.0.10 with Rails 8.1.4.1, RubyLLM 2.2.3
and the unchanged 0.5 instructions (prompt version 4), new OpenRouter
recordings cover the 0.6 features. Existing cassettes were not recorded again.

| Check | Executed result |
| --- | --- |
| Page context of a record | `openai/gpt-6-luna`, `anthropic/claude-haiku-5.5` and `google/gemini-3.8-flash` each called `get_record 9108` from the drawer's context line and filtered invoices by that customer; all answered 40 points and INV-4 only. The replay renders the record card and record table |
| Relation filters | All three models answered "Which invoices belong to customers with at least 20 points?" with `search_records` and `relation_filters: {customer: {points: {gte: 20}}}` (INV-3, INV-4) |
| Selection context | GPT-6 Luna read exactly the three selected customers and compared them |
| Bulk revision | GPT-6 Luna proposed one bulk change of 4 records; the person unticked one and edited the value; the conversation received "3 of 3 records were updated." |
| Evaluation set | 30 questions; the three new ones pass on GPT-6 Luna (`any` used for the OR count; the named-customer invoices found with a customer search and an invoice filter). 29 of 30 pass; `count-inactive` stays the recorded miss from 2026-11-22 |
| Defect found | The recorded totals replay showed the metric card as "This view cannot be rendered": the card passed its tab name to I18n as `scope:`. Fixed in `d55b5b7` |
| Fallback models | With the primary model's requests answered by a simulated 503 (WebMock), `anthropic/claude-haiku-5.5` as `assistant_fallback_models` answered all four requests of the reply through OpenRouter; each request first tried the primary model, and RubyLLM recorded those attempts as usage rows without tokens |
| Cost | About US$0.02 for all new recordings |
| Suites | SQLite and PostgreSQL 18: 759 tests / 7,089 assertions each, zero failures, run without `OPENROUTER_API_KEY` |

## 2026-11-22 — 0.5.0 release validation

On Ruby 4.0.10 and 3.3.14 with Rails 8.1.4.1, the SQLite suite passed 723 tests
and 6,657 assertions on both Ruby versions, with zero failures, errors or skips.
The 0.5.0 package
passed the fresh Rails authentication quickstart and session/SQLite host
checks, including template overrides. RuboCop inspected 378 files with no
offenses, and the frontend reproducibility check passed.

The [base commit CI](https://github.com/yorzi/rails_ai_admin/actions/runs/44996011303)
and [dependency checks](https://github.com/yorzi/rails_ai_admin/actions/runs/44996011328)
passed on `2092534`. Consult the release commit and signed tag runs for the
final CI results.

## 2026-11-22 — 0.5.0 development candidate

Requires Ruby >= 3.3 and Rails >= 8.1.4.1, < 8.2, as in 0.4. The package is
`0.5.0.dev`; publishing is blocked pending owner review. Results are local, at
`32562d1`; remote CI on the pushed commit must be checked separately.

| Check | Executed result |
| --- | --- |
| Ruby 4.0.10 and 3.3.14 × SQLite and PostgreSQL 18.4, Rails 8.1.4.1 | All four combinations: 702 tests / 6,500 assertions, zero failures, errors or skips, run without `OPENROUTER_API_KEY` |
| Rails main `666c152` (8.2.0.alpha), Ruby 4.0.10 × SQLite and PostgreSQL | 702 / 6,500 each, zero failures. Without the CSRF change, 7 CSRF tests fail; without the input partial change, form pages raise `ActionView::SyntaxErrorInTemplate` (all 5 errors in `resources_test.rb`, the file checked). All 64 HTML+ERB templates compile through Herb 0.11.2. Rails 8.2 remains unsupported |
| Recorded real-provider tests | All recordings made again on 2026-11-22 through RubyLLM 2.2.3's OpenRouter provider with prompt caching on, from empty cassettes: 8 scenarios (`openai/gpt-6-luna`; the reviewed update also with `anthropic/claude-haiku-5.5` and `google/gemini-3.8-flash`; operator notes with `anthropic/claude-haiku-5.5`) and the 27-question evaluation set on `openai/gpt-6-luna`. Final set about US$0.019, plus failed attempts |
| Caching | Every OpenAI and Anthropic recording reports cache reads, e.g. 15,325 of 17,348 tokens for operator notes on Claude Haiku 5.5; Gemini 3.8 Flash reports none |
| Evaluation results | 26 of 27 pass. `count-inactive` answered "4" correctly with `aggregate_records` instead of `count_records` and stays a recorded miss. `record-history` answered "No audited changes are listed"; the grader now accepts "no audited change" and "no admin change". `reference-label` was recorded again after a transient `PROVIDER_UNAVAILABLE` |
| Scenario attempts | Period groups first failed because the test resource did not declare `created_at` filterable (test fix). The isolation question "list the invoice numbers of Judy Jones" failed twice: the model searched invoice numbers for her name and never read the injected invoice; tenant isolation held. The question now names the customer lookup and passes |
| Fresh packaged Rails authentication quickstart | Passed: 2 / 21, generated authentication, registration, CRUD, revocation and rerun preservation |
| Packaged session / SQLite | 18 / 377; 19 / 450 with every catalogued template overridden; reload and production eager boot passed |
| Packaged Devise / Pundit / PostgreSQL | 28 / 453 on Propshaft and on Sprockets; production eager load passed |
| Recovery | Development reload, template reload, crash/replay, outbox death/retry/reconciliation and collection worker recovery passed against synthetic effects |
| Static checks | RuboCop: 377 files, no offenses; `npm run check --prefix frontend` passed |
| Dependencies | bundle-audit 0.9.3 with ruby-advisory-db `31efd9aa` (2026-11-21): no vulnerabilities in the main and docs bundles. npm audit: 0 vulnerabilities. `bundle outdated --only-explicit`: only webmock (test) |
| Documentation | Jekyll build serves tagged 0.4.1 at `/` and the 0.5 guides at `/next/`; `docs.py check`: 47 pages, no errors, two expected warnings for the `.dev` version |
| Candidate check | `rake release:check_candidate` passed with the publishing gate closed; `pkg/rails_ai_admin-0.5.0.dev.gem` sha256 `0936ed968b9cb00b6b2440e046ec90676f7e70daaa629fbe17daae1c725a02a3` |

Recorded replays show that this engine handles those model replies; they do not
show how a model answers today. Fallback models and the evaluation task are
tested against a scripted provider only. Native OpenAI and Anthropic APIs,
repeated live runs, a browser pass of this candidate, human screen-reader
validation and an independent host trial remain open.

## 2026-11-21 — Trix after Turbo navigation

On Ruby 4.0.9, Rails 8.1.4.1, RubyLLM 2.2.3, turbo-rails 2.0.23, Trix 2.1.19 and Chromium 159, a browser probe against `bin/demo` opened the article editor two ways: Turbo clicks from the overview, and a full page load. Before the change, the Turbo route applied 0 of 2 Trix styles, logged 4 style-policy errors and showed the link dialog open. With Trix loaded in the layout head, both routes applied 2 of 2 styles with no policy errors; the link dialog stayed hidden until the link tool was clicked, and an edit saved through Turbo. This resolves the observation recorded on 2026-11-18. The same probe injected an inline script into a Turbo-loaded list ([hotwired/turbo#1476](https://github.com/hotwired/turbo/issues/1476)). Turbo copied the `csp-nonce` onto it, but the admin's `script-src 'self'` carries no nonce, so the script did not run.

## 2026-11-18 — Unified offline demo

On Ruby 4.0.9, Rails 8.1.4.1, SQLite and Chromium 159, `script/demo/screenshots.cjs` passed against a fresh `bin/demo`. The browser covered global search, filters, saved views, CSV export/check/import, rich text and file updates, stale edits, soft delete and restore, single and bulk assistant reviews, record history and audit, a member action and a queued collection action, MCP read/proposal/revocation, and role and tenant separation. The SQLite suite passed 680 tests and 6,322 assertions. OpenRouter setup completed without a key, but no live requests were made.

Known browser observation: when Turbo first navigates to an article edit form, Chromium can reject Trix's dynamically inserted styles under the admin's CSP and show the link dialog prematurely. A full page load hides it as expected. The cause has not been isolated to an upstream component; the screenshot tour enters the edit form with a full navigation.

## 2026-11-18 (0.4.1 release base)

The release base `dfa8669` passed 680 tests and 6,322 assertions with zero
failures, errors or skips in all four Ruby 3.3.5 and 4.0.9 combinations with
SQLite and PostgreSQL 17. The suite ran on Rails 8.1.4.1 with offline provider
replays. Local checks also passed for RuboCop, frontend assets, the packaged
Rails quickstart, the session/SQLite host, the Devise/Pundit/PostgreSQL host on
Propshaft and Sprockets, and process-loss recovery. GitHub Actions passed both
the [CI run](https://github.com/yorzi/rails_ai_admin/actions/runs/44211677460) and
the [dependency security run](https://github.com/yorzi/rails_ai_admin/actions/runs/44211677367)
on this base. The [release commit CI](https://github.com/yorzi/rails_ai_admin/actions/runs/44214154306)
and [signed tag CI](https://github.com/yorzi/rails_ai_admin/actions/runs/44214777890)
passed for `bccc3b3`.

## 2026-11-15 — 0.4.0 release validation

Local Ruby 4.0.9 / Rails 8.1.4.1 passed 668 tests and 6,229 assertions on SQLite
and on PostgreSQL 17.12, without a provider key. RuboCop checked 370 files with no
offenses. The packaged quickstart and session/SQLite smokes passed against the
0.4.0 package. Remote CI on the release commit and tag provides the Ruby 3.3,
packaged-host, recovery, asset, dependency and documentation checks; consult its
GitHub Actions results separately.

## 2026-11-15 — 0.4.0 development candidate

Requires Ruby >= 3.3 and Rails >= 8.1.4.1, < 8.2, as in 0.3.0. The package is
`0.4.0.dev`; publishing is blocked pending owner review. Results are local; remote
CI on the pushed commit must be checked separately.

| Check | Executed result |
| --- | --- |
| Ruby 3.3.5 and 4.0.9 × SQLite and PostgreSQL 17.12, Rails 8.1.4.1 | All four combinations: 668 tests / 6,229 assertions, zero failures, errors or skips, run without `OPENROUTER_API_KEY` |
| Recorded real-provider tests | 35 tests replay HTTP recorded on 2026-11-15 through RubyLLM 2.2.0's OpenRouter provider: 7 scenarios (`openai/gpt-6-luna`; the reviewed update also with `anthropic/claude-haiku-5.5` and `google/gemini-3.8-flash`) and the 27-question evaluation set on `openai/gpt-6-luna`. Recording cost about US$0.02 |
| Evaluation results | First real run (23 questions): 19 passed. Three misses were correct answers the grader refused (typographic apostrophes, other wording); one was a real loop of one review per customer until the step limit. After bulk changes, the three-review cap and a wider grader, the recorded run of all 27 questions passes; each widened phrase was checked against the recorded answer |
| Fresh packaged Rails authentication quickstart | Passed: generated authentication, registration, CRUD, revocation and rerun preservation |
| Packaged session / SQLite | 18 / 377; 19 / 450 with every catalogued template overridden; reload and production eager boot passed |
| Packaged Devise / Pundit / PostgreSQL | 28 / 453 on Propshaft and on Sprockets; production eager load passed |
| Recovery | Development reload, crash/replay, outbox death/retry/reconciliation and collection worker recovery passed against synthetic effects |
| Browser | Local `bin/demo --assistant`: totals grouped by order state, the spend line refreshing after each reply, a bulk review card, the review page for 30 customers and its result page. The walkthrough found two defects, both fixed with regression tests: the spend line did not refresh until a reload, and Turbo dropped the 200 result page of a bulk change (also the bulk delete partial-failure page). `bin/demo --openrouter` was set up but not browsed |
| Static checks | RuboCop: 370 files, no offenses; reproducible frontend build passed |
| Dependencies | bundle-audit flagged Puma 8.0.2 (development and demo only), updated to 8.1.0; then no vulnerabilities in the main and docs bundles. npm audit: 0 vulnerabilities |
| Documentation | Jekyll build serves tagged 0.3.0 at `/` and the 0.4 guides at `/next/`; `docs.py check` reports no errors (two expected warnings for the `.dev` version) |

Recorded replays show that this engine handles those model replies; they do not
show how a model answers today. Native OpenAI and Anthropic APIs, repeated live
runs, `bin/demo --openrouter` in a browser, human screen-reader validation and an
independent host trial remain open.

## 2026-11-14 — 0.3.0 release validation

Local Ruby 4.0.9 / Rails 8.1.4.1 / SQLite passed 602 tests and 5,689 assertions.
The suite includes a regression test for reference sorting with a joined
authorization scope. RuboCop checked 357 files with no offenses.

## 2026-11-14 — 0.3.0 development candidate

Requires Ruby >= 3.3 and Rails >= 8.1.4.1, < 8.2, as in 0.2.0. The package is
`0.3.0.dev`; publishing is blocked pending owner review. Results are local; remote
CI on the pushed commit must be checked separately.

| Check | Executed result |
| --- | --- |
| Ruby 3.3.5 and 4.0.9 × SQLite and PostgreSQL 17.12, Rails 8.1.4.1 | All four combinations: 601 tests / 5,686 assertions, zero failures, errors or skips |
| Fresh packaged Rails authentication quickstart | 2 tests / 21 assertions; generated authentication, registration, CRUD, revocation and rerun preservation, including the saved views migration |
| Packaged session / SQLite | 18 / 377; 19 / 450 with every catalogued template overridden (including `resource_deleted`); reload, production precompile and eager boot passed |
| Packaged Devise / Pundit / PostgreSQL | 27 / 425; 28 / 453 with overrides, on Propshaft and on Sprockets |
| Recovery | Development reload, crash/replay, outbox death/retry/reconciliation and collection worker recovery passed against synthetic effects |
| Browser | Local demo: `in`, `contains` and `blank` filters, sorting orders by customer, numbered pages, saving and opening a view, one-step bulk delete with "all matching", soft delete and restore of an article, child Edit links; 390px without page overflow |
| Static checks | RuboCop: 357 files, no offenses; reproducible frontend build passed |
| Dependencies | bundle-audit: no vulnerabilities in the main and docs bundles; npm audit: 0 vulnerabilities |
| Documentation | Jekyll build serves tagged 0.2.0 at `/` and the 0.3 guides at `/next/`; `docs.py check` reports no errors |
| Candidate check | `release:check_candidate` passed on a clean tree with the publishing gate closed |

Human screen-reader validation, an independent host trial and current live
provider checks remain open.

## 2026-11-14 — 0.2.0 release validation

Local Ruby 4.0.9 / Rails 8.1.4.1 / SQLite: 569 tests, 5,343 assertions,
zero failures, errors or skips. RuboCop checked 345 files with no offenses.
Package metadata and release checks passed. Remote CI on the release commit
provides the database, Ruby 3.3, packaged-host, recovery, asset, dependency and
documentation checks; consult its GitHub Actions results separately.


## 2026-11-13 — 0.2.0 development candidate

Requires Ruby >= 3.3 and Rails >= 8.1.4.1, < 8.2. Rails 7 and 8.0 are not
supported. RubyGems' Rails API returned 8.1.4.1 as the latest release on this date.
The package remains `0.2.0.dev`; publishing is blocked pending owner review.

| Check | Executed result |
| --- | --- |
| Ruby 3.3.5 and 4.0.9 × SQLite and PostgreSQL 17.12, Rails 8.1.4.1 | All four combinations: 568 tests / 5,327 assertions, zero failures, errors or skips |
| Fresh packaged Rails authentication quickstart | 2 tests / 16 assertions; actual Rails app/auth generator, generated policy/resources, anonymous denial, signed-in create/update, audits, revocation and unchanged host files on installer rerun |
| Packaged session / SQLite | 17 / 346; 18 / 419 with overrides; generated anonymous test 1 / 2, reload, production precompile and eager boot passed |
| Packaged Devise / Pundit / PostgreSQL | 27 / 425; 28 / 453 with overrides on Propshaft and Sprockets; generated anonymous test 1 / 2, reload, production precompile and eager boot passed |
| Recovery | Outbox process-loss, idempotent retry, uncertain-outcome reconciliation and collection worker recovery passed against synthetic effects |
| Browser | Local demo sign-in, article list/title links, identity and sign-out; 320px menu expand/collapse and no document-wide horizontal overflow |
| Static checks | RuboCop: 345 files, no offenses; reproducible frontend build passed |
| Dependencies | Main and docs bundle-audit clean against 1,359 advisories at `305f8b079a23bf95d00c881842f366bb8db19f35` (2026-11-13); npm audit reports zero vulnerabilities |
| Documentation | Jekyll/RDoc build serves tagged 0.1.1 at `/` and the development guides at `/next/` |

Remote CI must be checked on the final commit separately. No release, tag,
provider call or documentation deployment is part of this preparation. Human
screen-reader validation and an independent production-like host trial remain open.

Earlier results below describe their historical builds, not the current support matrix.

## 2026-11-13 Public Preview candidate

Local results from the 0.1.0 preparation:

| Check | Result |
| --- | --- |
| Ruby 3.3.5 and 4.0.9, Rails 8.0.5.2 and 8.1.4.1, SQLite and PostgreSQL 17 | All eight combinations passed with 549 tests and 5,080 assertions before the chat UI update. The final local Rails 8.1/SQLite run passed 549 tests and 5,086 assertions with no skips |
| Ruby coverage for the Rails 8.1/SQLite suite | 6,108 of 6,494 executable lines (94.06%), 2,773 of 3,612 branches (76.77%) in 118 loaded Ruby files under `app/` and `lib/`. Excludes ERB, JavaScript, generator source templates and the version file loaded before instrumentation |
| Packaged session / SQLite | 17 tests / 346 assertions and 18 / 419 with overrides. Closed generated install, reload and production eager load passed |
| Packaged Devise / Pundit / PostgreSQL | 27 tests / 425 assertions and 28 / 453 with overrides on both Propshaft and Sprockets. Production asset builds, reload, outbox and collection crash recovery passed |
| Static and dependency checks | RuboCop and reproducible frontend build passed. npm audit and all three Ruby lockfiles reported no known advisories against the database updated on 2026-11-11 |
| Browser | Demo login, overview, list, keyboard search, filters, detail, new form and offline Chat. The redesigned chat was checked at desktop and 320px widths. The updated demo was exercised from a fresh seeded host through streaming search, a title change with explicit confirmation, and the audited history. At a 320px viewport only the records region scrolls horizontally. Documentation search, dark mode and the RDoc entry loaded |
| Documentation | 40 guide sources pass lint. Jekyll/RDoc build passes at the project base path. A temporary tagged fixture produced the 0.1.0 and `/next/` builds with 326 HTML pages and zero broken internal references, with versioned install examples, API URLs and sitemaps checked |

Exact-commit remote CI, Pages deployment, current live-provider verification
and a human screen-reader pass remain open.

## 2026-11-12 dependency update

Locks moved to the latest releases: Ruby 4.0.9 and Rails 8.1.4.1 were already
current; RubyLLM 2.1.1 → 2.2.0, minitest 6.1.0, Bundler 4.0.24, prism 2.1.0,
jekyll-vitepress-theme 1.12.0 and Host B esbuild 0.28.2. RubyLLM 2.2.0 broke
admin Chat on the 2.1 schema (38 failing engine tests); the 2.2 upgrade
migration and an earlier context binding fix it, and RubyLLM >= 2.2.0 is now
required. The Rails 8.0 lock keeps Rails 8.0.5.2 (the latest 8.0) and json 2.21.2.

- Engine suite: 473 tests / 4,062 assertions on Ruby 4.0.9 and 3.3.5, each with
  Rails 8.1.4.1 and 8.0.5.2, each on SQLite and PostgreSQL 17 (eight
  combinations). A second SQLite run on an existing database reruns the upgrade
  migration cleanly. One Rails 8.0/PostgreSQL run had a single failure that four
  reruns did not reproduce; it is not explained.
- Packaged Host A: 17 / 346; 18 / 399 with overrides. Host B (fresh RubyLLM 2.2
  product tables beside the admin's): 27 / 425; 28 / 453 with overrides on both
  Propshaft and Sprockets. Recovery and collection recovery probes pass.
- bundle-audit is clean for all three lockfiles against advisory DB
  `4d71b123428e33f694e805ce15351ee3d8d62ef7` (2026-11-11); npm audit is clean.
  RuboCop, asset reproducibility and the Jekyll build pass. No live provider call.

## 2026-11-06 release hardening

The feature branch was reconciled with remote main `9892431`, preserving the
standalone proposal API, Minitest 6 and the current Actions/theme/esbuild updates.
Current runtime locks use Rails 8.1.4.1, Addressable 2.9.2, Loofah 2.25.3,
Nokogiri 1.19.7 and rails-html-sanitizer 1.7.2; the Rails floor is now 8.1.4.1.
Both Ruby bundle audits pass against advisory DB
`516ea4757d5eec778c49af8371c23309c4b70f42` (2026-11-04, 1,351 advisories).

- Engine suites: 396 tests / 3,511 assertions on each of SQLite and PostgreSQL.
  New contracts cover page-size-independent and byte-bounded search continuation,
  late responses/tool calls after takeover, expired leases and replacement-worker
  recovery, native-only operation exposure, and alpha/beta/RC release metadata.
- All three original audit reproductions pass on each database. Provider I/O is
  asserted to run outside the message-persistence transaction. Billed usage for
  rejected stale responses stays accounted for.
- Packaged Host A: 17 / 344; 18 / 397 with all template overrides. Host B:
  27 / 420; 28 / 448 with overrides. Eager load, precompile and actual reload
  are checked; process-loss and both asset-pipeline checks run on the same package.
- RuboCop: 271 files, no offenses. Asset reproducibility and Jekyll/RDoc build
  pass. No live provider or new browser/accessibility pass is included here.

The first hardening CI candidate passed both engine suites, assets, docs and
security, but failed the consumer install because their exact Rails pins were
still 8.1.4. Old local consumer lockfiles had retained earlier same-version gem
metadata, masking the mismatch. Both hosts now pin 8.1.4.1; smoke scripts remove
their generated locks before resolving and verify the installed candidate's
runtime requirements, metadata and every packaged file in a separate process.
The release checker now rejects incompatible host Rails pins. Earlier consumer
runs on historical Rails 8.1.4 do not substitute for these corrected checks.

Remote CI must pass on the exact final candidate SHA. Earlier run links below
are historical and do not certify this candidate. The version remains
`0.1.0.dev` and RubyGems publishing remains blocked; I18n, human accessibility,
the broader security matrix and later Beta/1.0 gates remain open.

## Historical combinations

| Component / combination | Evidence |
| --- | --- |
| Ruby 4.0.9, Rails 8.1.4, JSON 3.1.0, macOS arm64 | Local core and request suites executed |
| SQLite (`sqlite3` 2.10.2) | 302 tests / 2,311 assertions, including fixed selections/current-authority manifests, table/key identity guards, collection admission/cancel/worker races, late lease guards, receipt replay, outbox fencing, request fingerprints, schema suggestions, installer preservation and atomic rollback |
| PostgreSQL 17.11 (`pg` 1.7.0), same Ruby/Rails | 302 tests / 2,311 assertions, including native UUID selections/targets, authorized joins/includes, same-pool delivery checks, collection item/admission/outbox contracts, concurrent cancel/claim and contention and atomic rollback |
| Packaged session / SQLite consumer, Propshaft 1.3.2, host importmap 2.2.3 | Actual `.gem` install, closed generated context, install rerun, schema suggestions with no automatic exposure, login/CSRF/CRUD, native fixed-selection capture/revocation, collection review/queue/results and custom-operation confirmation/replay plus host TestKit matrix (12 tests / 203 assertions), generated anonymous HTTP test (1 / 1), doctor, Zeitwerk, production eager load and precompile |
| Prebuilt Turbo 8.0.23 / Stimulus 3.2.2 | Reproducible esbuild output; Chrome login/list/show/form validation/save checked; nonce CSP without unsafe-inline; 320px and desktop CRUD spot checks; packaged Sprockets Host B custom-operation Turbo Stream review and explicit confirmation checked in Chrome at 500px, with no console/CSP errors; fixed-selection checkbox capture/303/current preview checked in the packaged Sprockets host at 500px with scrolling confined to the table |
| Ruby 4.0.9, macOS arm64, SQLite (`sqlite3` 2.10.2) and PostgreSQL 17 (`pg` 1.7.0), rails_tool_views 1.0.2 | 2026-11-03: 360 tests / 3,001 assertions on each database, adding belongs_to references and has_many panels (declaration and reflection contracts, one-query priming, indistinguishable unavailable targets, bounded grant-ordered choices, visible-only writes, unchanged/cleared references, a foreign-key race mapped to CONFLICT, eq filters, panels and escaping); mutations removing the write check, priming or the conflict mapping each failed. Packaged Host A with `Order belongs_to :customer` and `Customer has_many :orders`: 17 / 309; 18 / 343 under all 29 overrides (every catalogued template rendered) and real reload. Host B unchanged: 25 / 338; 26 / 356 with overrides on Propshaft and Sprockets, production eager load. Not yet run: remote CI for this branch, Chromium/accessibility checks of the picker and panel |
| Ruby 4.0.9, macOS arm64, SQLite (`sqlite3` 2.10.2) and PostgreSQL 17 (`pg` 1.7.0), rails_tool_views 1.0.2, RubyLLM 2.1.1 | 2026-11-03 (admin Chat, ADR 0022): 382 tests / 3,181 assertions on each database. RubyLLM's real OpenAI provider, chat-completions parser, tool loop and persistence run against WebMock fixtures: keyed admission and strict turn order, provider retry without a repeated message, reconciliation of an answer persisted before a crash, fencing before provider steps and tool calls, grant-filtered tools, unavailable AI and revoked authority with no provider call, the step limit, proposal replay, equal-id product chat isolation, and HTTP Chat → Surface → one write → one continuation. Mutations removing the message once-guard, the continuation, the step fence, the tool fence or the exposure grant each failed a test. Packaged Host B (Devise, Pundit, PostgreSQL, its own ProductChat and product Surface) runs the generator, a Pundit `assistant?` grant and the full flow with real per-form CSRF: 26 / 369; 27 / 387 with all 29 overrides on Propshaft and Sprockets, production eager load; global RubyLLM settings, product messages and product usages unchanged. Host A stays AI-free: 17 / 309; 18 / 343, `RubyLLM` undefined. Chromium against packaged Host B in development with a loopback fixture provider (async jobs, Turbo Frame polling, keyboard confirmation, 320px) found and fixed three defects: Stop outside the polled frame, quirks-mode frame responses, and a sent message hidden until the worker ran. No live provider call; not yet run: remote CI for this branch, screen reader |
| Ruby 4.0.9, macOS arm64, PostgreSQL 17, RubyLLM 2.1.1 OpenRouter provider (live) | 2026-11-03, live provider: packaged Host B ran the full flow with no WebMock against `openai/gpt-4.1-mini`, `anthropic/claude-haiku-4.5` and `google/gemini-3.8-flash`, one run each, through OpenRouter's chat-completions API with a disposable copy of the host adapter: a foreign-tenant ticket returned `NOT_FOUND` (Gemini also probed the closed archive) with no foreign value in any tool result or reply, parallel tool calls, a proposal shown as the admin Surface, a real per-form CSRF confirmation that triaged once with one outbox item, a repeated confirmation that wrote nothing and admitted no second continuation, one continuation answer, usage rows owned by the admin chat, and unchanged global RubyLLM settings (44–56 assertions per model; 5–6 provider requests, 10–16 s first turn, under US$0.03 across all five live runs). The first run found that `describe_resource` hid enum input values; after the fix the engine suite is 382 / 3,182 on each database and Host B is still 26 / 369. Not covered: the native OpenAI and Anthropic APIs, provider errors and crash recovery against a live provider, a browser session with a live provider, repeated runs per model |
| Ruby 4.0.9 (built from the upstream v4.0.9 tag), Linux x86_64, SQLite (`sqlite3` 2.10.2) and PostgreSQL 16.15 (`pg` 1.7.0), rack 3.2.8, rails_tool_views 1.0.2 | 2026-11-01: 343 tests / 2,829 assertions on each database (engine app loads rails_tool_views with no global configuration), including admin review Surfaces (both confirmation orders, replay, stale revision, revocation, changed record, failure rollback, foreign/unbound/product scopes, lapsed grants, Turbo Stream, re-registration, squatting), index settings, typed filters and named scopes; packaged Host A without rails_tool_views (16 / 289; 17 / 323 under every template override; no Surface routes or integration after production eager load) and its real reload; Host B with its own product Surface on Propshaft and Sprockets (25 / 338; 26 / 356 with overrides), real per-form CSRF, product-route isolation and admin re-registration after host reload; recovery and collection process-loss probes. Chromium (Playwright 1.63) checked Host A tabs/filters/tables and the Host B Surface flow (hand-off, reload, keyboard confirm via Turbo Stream) at 1280px and 320px with no console/CSP/HTTP errors. bundle-audit clean. Remote GitHub Actions passed on Ruby 4.0.9 for commit 69b4147: SQLite and PostgreSQL suites, both packaged hosts including the Host B Surface flow, Sprockets, assets, docs and dependency audit |
| Prebuilt Turbo 8.0.23 / Stimulus 3.2.2 | Reproducible esbuild output (0.28.2 since 2026-11-01); Chrome login/list/show/form validation/save checked; nonce CSP without unsafe-inline; 320px and desktop CRUD spot checks; packaged Sprockets Host B custom-operation Turbo Stream review and explicit confirmation checked in Chrome at 500px, with no console/CSP errors; fixed-selection checkbox capture/303/current preview checked in the packaged Sprockets host at 500px with scrolling confined to the table |
| Ruby 4.0.9 (built from the upstream v4.0.9 tag), Linux x86_64, SQLite (`sqlite3` 2.10.2) and PostgreSQL 16.15 (`pg` 1.7.0), rack 3.2.8, rails_tool_views 1.0.2, ruby_llm 2.1.1, Minitest 6.0.6 with minitest-mock 5.27.0, esbuild 0.28.2 | 2026-11-01: 347 tests / 3,029 assertions on each database (Minitest 6 counts more assertions than 5.27's 2,888 for the same tests) (engine app loads rails_tool_views with no global configuration), including an offline RubyLLM tool loop (WebMock, network disabled) proposing into the review Surface, admin review Surfaces (both confirmation orders, replay, stale revision, revocation, changed record, failure rollback, foreign/unbound/product scopes, lapsed grants, Turbo Stream, re-registration, squatting), index settings, typed filters and named scopes; packaged Host A without rails_tool_views (16 / 321; 17 / 374 under every template override; no Surface routes or integration after production eager load) and its real reload; Host B with its own product Surface and RubyLLM product chat on Propshaft and Sprockets (26 / 385; 27 / 413 with overrides, including the offline assistant triage proposal), real per-form CSRF, product-route isolation and admin re-registration after host reload; recovery and collection process-loss probes. Chromium (Playwright 1.63) checked Host A tabs/filters/tables and the Host B Surface flow (hand-off, reload, keyboard confirm via Turbo Stream) at 1280px and 320px with no console/CSP/HTTP errors. bundle-audit clean. Chromium rechecked the Host B Surface flow and the Host A filter flow on the esbuild 0.28.2 bundle. Remote GitHub Actions passed on Ruby 4.0.9 for commit 02eb89c with actions/checkout 7.0.1 and actions/setup-node 7.1.0: SQLite and PostgreSQL suites, both packaged hosts, Sprockets, assets, docs and dependency audit |
| Independent packaged Host B: Devise 5.0.4 / Pundit 2.5.2 / PostgreSQL | Real login/CSRF/logout/timeout, role/tenant grants, UUID replay/selection, independent selection grants, collection partial cancellation, separate parent/item grants and synthetic outbox effects, alias scope, product SDK coexistence and TestKit matrix: 20 tests / 237 assertions; generated anonymous HTTP test (1 / 1). Existing mount in a `draw` route file preserved |
| Host B Propshaft 1.3.2 or Sprockets 4.4.1 / sprockets-rails 3.5.2, jsbundling-rails 1.3.1 | Both production precompiles and eager boots passed; host esbuild 0.25.12 bundle built; each variant passed Host B acceptance. These are two variants of one host |
| Host B development reload and process recovery | Real source reload replaced computation/field/model/resource/policy/context/Operation/Work classes and registries; a changed plugin version rejected old field contracts; killed precommit transaction rolled back domain/claim/audit; response-loss replay returned one receipt. Separate worker processes died before/after synthetic effects: expired-lease idempotent replay applied once, non-idempotent pre-effect retry succeeded, and unknown non-idempotent outcome required reconciliation without resend |
| Real providers | One full flow per model family through OpenRouter on 2026-11-03 is recorded above. Native OpenAI/Anthropic APIs and live failure recovery remain unverified; no paid call was made during the 2026-11-06 hardening pass |
| Assistant evaluation set | `test/assistant_eval/questions.yml`: 20 fixed questions (counts with and without a scope, filters and ranges, sort, contains and non-ASCII search, a reference label, a two-step count, another tenant's record, an ungranted field, a proposal, a refused delete and two prompt injections), graded for tool calls, result values, answer text, proposals, unchanged business data and no foreign or ungranted values. 2026-11-10: the offline replay passes 21 / 21 through RubyLLM's real tool loop; reverting the RAA-007 fix fails 4 questions. **Live run pending:** run it against at least one real model before each release (instructions in `test/contract/assistant_eval_test.rb`) and record the model, date and score here. No paid call was made on 2026-11-10 |

Current runtime bounds: Ruby >= 3.3 (development pins `.ruby-version` 4.0.9); Rails >= 8.1.4.1 and < 8.2; json >= 2.13; json_schemer ~> 2.5; base64 ~> 0.3; turbo-rails ~> 2.0; stimulus-rails ~> 1.3. Optional, from the host's Gemfile and
checked at boot only when the feature is on: rails_tool_views ~> 1.0.2 (`config.surfaces`) and RubyLLM >= 2.2.0 and
< 3 (`config.assistant`). These bounds are candidate dependency constraints, not proof every resolvable combination works.
The lockfile records actual resolution, including Linux/source platform metadata.

Published rails_tool_views 1.0.2 package SHA-256:
`3d169601f62005fff6e510b604e377585edc308b31c92a4df6cc21b3a0789d50`.
Host A conventional packaged boot did not load RubyLLM/rails_tool_views constants, create
AI/runtime tables, access provider keys or call a provider. A host already using
both SDKs (Host B) preserved its product Chat/Message, Surface and global settings
through conventional admin CRUD/member/collection operations and development reload. With
admin Chat enabled, Host B also kept them unchanged while admin ToolCall/Usage rows used
RubyLLM's shared tables with per-chat polymorphic scoping and admin-chat usage owners.
Live-provider acceptance remains open.

Scalar extension acceptance covered immutable class-name registration, constrained
wire schemas, read-only hooks, HTML-safety removal, normalization idempotence,
version-bound forms/Selections and per-record projection keys before rendering.
Both packaged consumers use a real host `TrimmedTextField` and custom form/display
partials. Host B tests fixed Select labels, unavailable-value preservation,
validation recovery and normalized writes on both pipelines. Typed Date/Time and
exact Decimal proposals confirm/replay through the public Ruby Runner API.
The full SQLite suite also passed on a newly created database; domain fixture DDL
is prepared before transactional request tests. RuboCop passed 224 Ruby files;
24 guide pages passed documentation lint and Jekyll/RDoc build. These are local
contracts and package evidence; they do not establish assistive-technology coverage.
Computed-field contracts additionally cover recursive own/dependency grants,
unsupported/mutable snapshots, graph/size/cooperative duration bounds, physical
getter write prevention, current formatted titles and stale version/edge changes.
A 25-row index uses one domain query and computes each title once. Host A derives
its active/points summary after actual writes; Host B hides a computed review
summary when a viewer lacks its internal-note dependency, despite an explicit
summary grant. Real source reload replaces the computation and rejects the old
field contract.

The initial template override milestone added fixed paths/context revisions and
metadata inspection, never host ERB evaluation. At that checkpoint, root contracts
covered the initial 24 copied sources, Unicode, exclusive-create races, path/header/inventory bounds and independent
source/context drift. Native request tests preserve escaping, one layout/form,
CSRF/intent and new/edit failure wrappers. Packaged Host A additionally passed
10 tests / 156 assertions with generated host overrides; actual render notifications
covered all 24 keys. Host B passed 21 tests / 255 assertions in its override mode
on both pipelines, rendering its 18-key HTTP subset and verifying stale source
metadata. Actual development reload changed a host template body and controller
while preserving upstream metadata. These counts are separate from normal host
acceptance above. Temporary overrides were removed after each mode; no installer
copies the full view tree. The later status/controller milestone below expands
this catalog and evidence. Arbitrary dynamic view-path metadata, non-HTML plain
responses and future Surface wrappers remain outside the template catalog.

Per-view field controls additionally cover global hidden-field exclusion, static
index/show output visibility, recursive dependency permission masks, immutable
plain grouping/help metadata, current generic write masks (including create after
assignment), optional Pundit hooks and fail-closed invalid/private/writing hooks.
Direct scalar reads enforce current resource identity and view grants. Native
request tests verify blank write-only prefills, readonly context, removed empty
groups, denied input rejection, raw failed input, linked errors/help and DOM-ID
uniqueness with legitimate `name_help`/`name_error` fields.

A packaged Host A Chrome run verified ARIA tabs, real ArrowRight keyboard focus,
hidden enabled controls retained in FormData, first-invalid native validation
across sections (including a dynamically required custom text control and built-in
numeric step validation), server 422 focus/selected section/input retention and
summary-link revelation/focus. No console/CSP errors were recorded during those
checks. The 390px dark layout had document width 390px and was visually inspected.
Server markup has two visible sections and anchor navigation before enhancement;
a browser with scripting disabled and assistive technology were not exercised.
The task's temporary browser tab and loopback host were closed/stopped. This is
Chrome spot coverage, not the complete browser/accessibility gate. Persistent session drafts remain unimplemented. Generic open-tab recovery is
covered below.

Generic form-session recovery contracts additionally cover same-owner/root UI
intent eligibility, fresh epoch/permissions, absolute one-hour age, unchanged
version/schema, input-bound/preapproved/child/delete rejection, current editable
field narrowing, safe response markers and render-error redaction. Host A loses
its session and Host B exercises a real 31-minute Devise timeout; both reauthenticate,
recover the original UUID, obtain fresh CSRF and save once. Neither recovery GET
executes domain work or creates another intent.

Chrome in packaged Host A verified actual session rotation in a second tab,
marked CSRF 422 preservation with Save disabled, manual Resume with the same UUID,
raw name/leading-zero input retention, dirty state and a fresh-token explicit 303
save. A held recovery response proved edits typed during the wait are retained.
A second-tab committed edit produced a recovery 409 while the original stale draft
stayed visible/unsaved and Save remained disabled. localStorage/sessionStorage
remained empty in the isolated browser context. Expected HTTP 422/409 network
messages appeared; no application JS/CSP error was seen. The temporary browser
tabs and host were stopped. This does not prove native 401 interaction in Chrome,
no-JavaScript input recovery, persistent drafts or custom-operation recovery.

List navigation contracts additionally cover bounded structured hints, routing/
URL injection rejection, current index/search/sort grants, one-step stale-setting
redirects, same-filter/tenant empty-page clamping, PK tie-breaking across pages,
unchanged command replay identity and state across member/selection/collection/
job/cancel flows. Actual PostgreSQL NUL search and invalid UTF-8 page probes exposed
framework input-validation gaps; guards now return INVALID_QUERY before adapter
serialization. base64 0.3.0 is now a direct dependency for the ASCII header codec;
no resolved package version changed in this milestone.

Packaged Host A verifies a Unicode page-2 list, recovery and deleting the final
matching row into a canonical filtered page 1. Host B verifies Unicode/current
sort through recovery and an explicit UUID update on both asset pipelines.
Chrome in Host A checked Chinese/emoji search + descending sort + page 2 through
show/edit, real session rotation/CSRF pause, the same-intent Resume and Save. An
edit that removed the final match returned to filtered page 1 with a notice.
Sort toggling and actual browser Back restored query/direction. Injecting a bad
encoded hint into the synthetic form produced a visible fallback notice, no
navigation fields, a safe default Cancel link and no business mutation; input
remained in the open DOM. The expected CSRF 422 network message appeared; no
application JS/CSP error was seen. Temporary tabs and host were closed/stopped.
Empty-page counts cap matching relation rows at 25,000, not physical SQL scanning;
concurrent changes remain best-effort, and no scale/browser matrix is certified.

The custom-controller/status milestone adds fixed safe HTML status pages and
public protected Context/Access/Runner/mounted-route/CSP-nonce helpers for normal
host controllers. Request tests retain host helpers and SCRIPT_NAME, default-deny
scoped projections, route/CSRF binding, anti-enumeration, Turbo reload, plain
non-HTML fallback and redacted template-failure fallback; unhandled action errors
still reach host error handling. A real unique-index rejection now returns
CONFLICT with rollback rather than escaping as RecordNotUnique. SQLite and PG
both passed 289 tests / 2,218 assertions; the fresh SQLite database and previously
failing routing-order seed 37334 also passed. Fake installer mounts are isolated
from real route helpers; this does not establish multi-host/multi-mount support.

Host A's distinct Order domain adds exact decimal/date/false CRUD, model validation,
readonly state, current field/computation grants and a normal host-owned review
workbench sharing the native operation. Normal acceptance passed 12 / 203;
overrides passed 13 / 237 with all 26 catalog entries actually rendered. Both Host B
pipelines retained 20 / 237 normal and 21 / 255 override acceptance, rendering their
20-key HTTP subset and inspecting all 26 metadata entries. A real Host A source
reload replaced controller/resource/operation/registry objects, HTTP used the new
controller and rejected an old operation-version approval without a business write.
Production precompile/eager boots passed for each consumer variant.

Chrome found a fixture preview incompatibility: Turbo requires a redirect or
Turbo Stream for a successful POST, whereas the host action rendered HTML 200.
The preview form now uses ordinary non-Turbo submission; confirmation redirects
303. After correction, actual preview displayed normalized input while the order
stayed draft, explicit confirmation approved it once, and the approved edit URL
rendered only fixed 404 content. The custom layout's nonce meta matched the CSP;
no application JS/CSP error appeared in the successful flow. A separate native
Order edit survived second-tab session rotation, marked CSRF 422/disabled Save,
same-intent Resume with exact total/date/false values and explicit Save. DB checks
showed one success audit/version increment for each of these two writes, and
localStorage/sessionStorage stayed empty. The expected CSRF 422 network entry
remained. The 390px dark workbench was visually inspected without horizontal
overflow. Temporary tabs and loopback host were closed/stopped. This does not
establish custom-operation recovery, Surface/provider behavior or the full browser
and accessibility matrix. These are three author-controlled domain resources,
not the plan's three independent migration/adoption samples.

The resource-menu milestone adds static group/label/fixed-icon/order/hidden
settings over fresh index grants. Contract/request tests cover caption bounds,
denied-metadata laziness, grouping order, escaping, SCRIPT_NAME, per-request
grants, hidden direct access, boot-time fallback-label rejection and unchanged
intent/Selection identity. Review moved fallback-label rejection to registration;
before that, one unusable label would have made every admin page return 503.
SQLite and PG both passed 302 tests / 2,311 assertions. Host A normal acceptance
passed 13 / 214 and overrides 14 / 248 with all 27 catalog entries rendered; its
real reload renamed the Order menu group/label and HTTP rendered the new menu.
Both Host B pipelines passed 21 / 251 normal and 22 / 269 override acceptance,
including Pundit-granted Support entries that disappear for a suspended role,
rendering a 22-key HTTP subset and inspecting all 27 metadata entries. Production
eager boots passed for each variant. No Chrome, mobile-layout or screen-reader
check was made for the menu.

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
reserved and no trademark clearance is claimed. The remote repository and CI
now exist; the package remains unreleased, without a release tag or RubyGems
publishing authorization.

Dependency and docs lockfiles passed bundler-audit against advisory DB commit
`920f5cd5e02cbe598f60afb02f533d608133b795` (1,284 advisories). Frontend installation
reported no npm advisories. These scans are dated evidence, not a security proof.
