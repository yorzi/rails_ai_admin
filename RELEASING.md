# Releasing

No version of `rails_ai_admin` has been published. This file defines what the
next release must prove and the mechanical steps to cut one. A green checklist
is evidence for a decision; it is not the decision. Only the owner approves a
release and opens publishing.

## Release ladder

The [development plan](docs/development-plan.md) (§0.6) defines these labels. Each one must be earned in
order and cannot be claimed early:

| Label | Version | Must prove |
|---|---|---|
| Internal acceptance | `0.1.0.dev` (current) | Default-deny CRUD through one shared, audited Operation boundary |
| Early integration proof | not published | One Order form works on native pages and a trusted Surface; an offline Chat loop recovers without duplicate writes |
| **Public Preview** (next) | `0.x`, limits listed | Listed CRUD, associations and filters; one complete Chat+Surface workflow; full use with AI disabled |
| Beta | `0.x` Beta | Every P0 candidate implemented, two packaged hosts, 100 deterministic evaluations, real-provider checks |
| 1.0 | `1.0.0` | Every P0 plus Gates A–E, three migration samples, independent trials, owner approval |

## Public Preview readiness

Status on 2026-11-13 (Public Preview preparation). "Local" means verified in this repository and its packaged
hosts, not by external users.

| Requirement | Status | Evidence or gap |
|---|---|---|
| Basic CRUD, fields and validation | Local | Three domains in packaged hosts (ADRs 0009–0015) |
| Index, search, sort, pagination | Local | ADR 0014, 0019 |
| Typed filters and named scopes | Local | ADR 0017, 0018 |
| Associations | Partial | `belongs_to` and readonly `has_many` panels (ADR 0021). Picker search past 100 targets. Open: association columns, has_one/through, attach/detach policies |
| Navigation and basic permissions | Local | ADR 0002, 0016 |
| Operable Surface | Local | Admin review Surfaces (ADR 0020) |
| AI disabled path | Local | Host A runs with no AI tables, keys or routes |
| Chat entry (UI/Chat dual entry) | Local | Opt-in admin Chat with grant-filtered tools and proposals as review Surfaces (ADR 0022); Host B and Chromium against offline fixtures; Host B against live models |
| Early integration proof exit gate | Local | Chat → Surface → one write → one continuation, crash/retry/fencing recovery offline; the same flow live on 2026-11-03 |
| Live provider check | Local | 2026-11-03: Host B full flow against OpenAI, Anthropic and Google models through OpenRouter, one run each. Native OpenAI/Anthropic APIs and live failure recovery remain open (RAA-0509) |
| Dependency security | Local clean | 2026-11-13: the main, Rails 8.0 and docs lockfiles pass bundle-audit (advisory DB of 2026-11-11) and the frontend passes npm audit; exact candidate CI remains required |
| Reproduced correctness defects | Locally fixed | Late worker responses, search pagination and prerelease release metadata have regression tests (COMPATIBILITY.md) |
| Phase 2 security regressions (RAA-0210) | Local | `test/integration/security_regressions_test.rb`: every non-GET engine route (Surface and Chat included) rejects a missing CSRF token with no side effect; unwritable, framework and tenant attributes are never assigned; record text and request values are escaped on every page; list and selection pages keep a constant query count. CSRF and XSS checks were mutation-tested |
| Framework I18n | Local | Every page, notice, status, field message, Chat message and script message reads `config/locales/en.yml`; the test app raises on a missing key, and a test renders a host locale (Translations guide) |
| Accessibility pass | Local (automated) | 2026-11-13, Chromium Lighthouse (axe) in the packaged demo host: 100 on overview, list with filters and reference picker, record with association panel, new form with picker results, delete confirmation, jobs and a 404 status page; picker keyboard path and 320px width checked. A screen-reader pass by a person remains open |
| Remote CI on the release commit | Required per candidate | Historical main CI passed on 9892431. The `release/v0.1.0` candidate is local and unpushed; it must pass CI on its own exact SHA |
| Listed limitations in release notes | Drafted | The 0.1.0 section of CHANGELOG.md lists CSV, files, dashboards, Chat limits (no streaming, budgets, page context or retention) and the open association, accessibility and provider gaps |
| Owner approval and publishing | Owner only | `allowed_push_host` blocks `gem push` today |

**Verdict:** locally ready for Public Preview; not yet published. Every
product row has local evidence or is listed as a limitation in the release
notes. Two steps remain, and neither can be done from this repository alone:
remote CI must pass on the exact candidate commit, and the owner must approve
the label and open the publish gate. A screen-reader pass and an independent
install trial are recommended before publishing but are not Public Preview
gates in the ladder above.

Publishing an earlier, conventional-only prerelease (for example
`0.1.0.alpha1` with AI disabled and every gap listed) would depart from the
plan's ladder. Only the owner can decide that; nothing in this repository
assumes it.

## Cutting a release

Run every step from a clean checkout of the release branch.

1. **Decide.** The owner records approval for the exact label and version. Close
   or explicitly list every open row above.
2. **Branch.** `git switch -c release/vX.Y.Z` from `main`.
3. **Synchronize the version.** Update each of these to the same value:
   - `lib/rails_ai_admin/version.rb`
   - the exact pins in `spec_hosts/session_sqlite/Gemfile` and
     `spec_hosts/devise_postgres/Gemfile`
   - `version` and `released: true` in `docs/site/_config.yml`
   - a `## X.Y.Z (YYYY-MM-DD)` section in `CHANGELOG.md` (including alpha/beta/RC suffixes) holding the former
     Unreleased entries, with the release's listed limitations
   - `docs/site/_reference/upgrading.md` and `release-history.md`
4. **Verify locally.**

   ```sh
   bundle exec rubocop --cache false
   bundle exec rake test                                  # SQLite
   RAA_TEST_DATABASE_URL=postgresql://…/raa_test bundle exec rake test
   npm ci --prefix frontend && npm run check --prefix frontend
   bundle exec rake build
   bundle exec ruby script/packaged_smoke.rb
   bundle exec ruby script/packaged_support_smoke.rb     # with RAA_HOST_B_DATABASE_URL
   RAA_ASSET_PIPELINE=sprockets bundle exec ruby script/packaged_support_smoke.rb
   bundle exec ruby script/packaged_recovery_smoke.rb
   bundle exec ruby script/packaged_collection_recovery_smoke.rb
   docs/site/bin/build.sh
   bundle exec rake release:check
   ```

   `release:check` distinguishes unpublished `.dev` builds from alpha/beta/RC
   versions intended for publication. Published prereleases also need
   `released: true`, a versioned changelog section and explicit owner approval.
   It must report no errors. For any version intended for publication it fails until
   the owner opens the publish gate in step 6.
5. **Record evidence.** Add the executed combinations and counts to
   `COMPATIBILITY.md`, and push the branch so remote CI runs on that commit.
6. **Open the gate (owner).** In the release commit only, change
   `allowed_push_host` in `rails_ai_admin.gemspec` to `https://rubygems.org`.
   Rerun `rake build` and `rake release:check`, then record the package SHA256.
7. **Tag and publish (owner).** Merge, then create a signed tag `vX.Y.Z` on that
   commit and wait for green CI on the tag. Push the gem with MFA
   (`gem push pkg/rails_ai_admin-X.Y.Z.gem`), create the GitHub release with the
   changelog section and SHA256, and deploy the docs.
8. **Reopen development.** On `main`, add an empty `## Unreleased` section, move
   the version to the next `.dev`, set `released: false` and restore the blocked
   `allowed_push_host`. `release:check` returns to the development state.

Never publish from a dirty tree, from an untagged commit, or with a package
whose digest differs from the recorded one.
