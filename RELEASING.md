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
| Internal acceptance | `0.1.0.dev` | Default-deny CRUD through one shared, audited Operation boundary |
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
| Associations | Local with limits | `belongs_to`, picker search past 100 targets, readonly `has_many` and `has_one` panels, and editable many-to-many references. Association sorting, polymorphic writes, nested forms and separate attach/detach policies stay open. |
| Navigation and basic permissions | Local | ADR 0002, 0016 |
| Operable Surface | Local | Admin review Surfaces (ADR 0020) |
| AI disabled path | Local | Host A runs with no AI tables, keys or routes |
| Chat entry (UI/Chat dual entry) | Local | Opt-in Chat with streamed replies, grant-filtered tools, page context and reviewed proposals. MCP exposes the same tools through personal tokens. Earlier live runs used OpenRouter. |
| Early integration proof exit gate | Local | Chat → Surface → one write → one continuation, crash/retry/fencing recovery offline; the same flow live on 2026-11-03 |
| Live provider check | Local | 2026-11-03: Host B full flow against OpenAI, Anthropic and Google models through OpenRouter, one run each. Native OpenAI/Anthropic APIs and live failure recovery remain open (RAA-0509) |
| Dependency security | Local clean | 2026-11-13: the main, Rails 8.0 and docs lockfiles pass bundle-audit (advisory DB of 2026-11-11) and the frontend passes npm audit; exact candidate CI remains required |
| Reproduced correctness defects | Locally fixed | Late worker responses, search pagination and prerelease release metadata have regression tests (COMPATIBILITY.md) |
| Phase 2 security regressions (RAA-0210) | Local | `test/integration/security_regressions_test.rb`: every non-GET engine route (Surface and Chat included) rejects a missing CSRF token with no side effect; unwritable, framework and tenant attributes are never assigned; record text and request values are escaped on every page; list and selection pages keep a constant query count. CSRF and XSS checks were mutation-tested |
| Framework I18n | Local | Every page, notice, status, field message, Chat message and script message reads `config/locales/en.yml`; the test app raises on a missing key, and a test renders a host locale (Translations guide) |
| Accessibility pass | Local browser checks | Candidate checks covered keyboard search, named search landmarks and 320px list scrolling. An earlier build passed Lighthouse (axe) on seven sample pages. A human screen-reader pass remains open. |
| Remote CI on the release commit | Pending | The exact release commit and tag must pass CI. See COMPATIBILITY.md for local evidence. |
| Listed limitations in release notes | Drafted | The 0.1.0 section of CHANGELOG.md and the What's New guide list the association, Chat, accessibility and provider limits. |
| Owner approval and publishing | Owner only | `allowed_push_host` blocks `gem push` today |

The 0.1.0 candidate still needs CI on the exact release commit and the owner's
approval to publish. The docs build targets the custom GitHub Pages domain
`rails-ai-admin.wangyaodi.com`. Verify the Pages source and the Cloudflare
CNAME before publishing the site.
A screen-reader pass and an independent install trial remain recommended.

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
   bundle exec rake release:check_candidate
   ```

   `release:check_candidate` checks versioned docs, changelog, packaged files,
   host pins and package metadata while the owner gate remains closed. CI runs
   this check. Use the strict `release:check` after opening the gate in step 6.
   Alpha, Beta and RC editions use versioned changelog sections and
   `released: true` like other releases.
5. **Record evidence.** Add the executed combinations and counts to
   `COMPATIBILITY.md`, and push the branch so remote CI runs on that commit.
6. **Open the gate (owner).** In the release commit only, change
   `allowed_push_host` in `rails_ai_admin.gemspec` to `https://rubygems.org`.
   Rerun `rake build` and `rake release:check`, then record the package SHA256.
7. **Tag and publish (owner).** Merge, then create a signed tag `vX.Y.Z` on that
   commit and wait for green CI on the tag. Push the gem with MFA
   (`gem push pkg/rails_ai_admin-X.Y.Z.gem`), create the GitHub release with the
   changelog section and SHA256. Confirm Pages uses the GitHub Actions source.
   The Publish documentation workflow runs on a published release and can also
   be run manually. Verify the live homepage, the install command, `/next/`
   and the RDoc entry after deployment.
8. **Reopen development.** On `main`, add an empty `## Unreleased` section, move
   the version to the next `.dev`, set `released: false` and restore the blocked
   `allowed_push_host`. `release:check` returns to the development state.
   Run Publish documentation manually to refresh `/next/`.

Never publish from a dirty tree, from an untagged commit, or with a package
whose digest differs from the recorded one.
