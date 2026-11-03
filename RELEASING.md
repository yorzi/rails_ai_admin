# Releasing

No version of `rails_ai_admin` has been published. This file defines what the
next release must prove and the mechanical steps to cut one. A green checklist
is evidence for a decision; it is not the decision. Only the owner approves a
release and opens publishing.

## Release ladder

The development plan (§0.6) defines these labels. Each one must be earned in
order and cannot be claimed early:

| Label | Version | Must prove |
|---|---|---|
| Internal acceptance | `0.1.0.dev` (current) | Default-deny CRUD through one shared, audited Operation boundary |
| Early integration proof | not published | One Order form works on native pages and a trusted Surface; an offline Chat loop recovers without duplicate writes |
| **Public Preview** (next) | `0.x`, limits listed | Listed CRUD, associations and filters; one complete Chat+Surface workflow; full use with AI disabled |
| Beta | `0.x` Beta | Every P0 candidate implemented, two packaged hosts, 100 deterministic evaluations, real-provider checks |
| 1.0 | `1.0.0` | Every P0 plus Gates A–E, three migration samples, independent trials, owner approval |

## Public Preview readiness

Status on 2026-11-03. "Local" means verified in this repository and its packaged
hosts, not by external users.

| Requirement | Status | Evidence or gap |
|---|---|---|
| Basic CRUD, fields and validation | Local | Three domains in packaged hosts (ADRs 0009–0015) |
| Index, search, sort, pagination | Local | ADR 0014, 0019 |
| Typed filters and named scopes | Local | ADR 0017, 0018 |
| Associations | Partial | `belongs_to` and readonly `has_many` panels (ADR 0021). Open: picker search endpoint, association columns, has_one/through, attach/detach policies |
| Navigation and basic permissions | Local | ADR 0002, 0016 |
| Operable Surface | Local | Admin review Surfaces (ADR 0020) |
| AI disabled path | Local | Host A runs with no AI tables, keys or routes |
| **Chat entry (UI/Chat dual entry)** | **Missing** | SPIKE-03/RAA-0251: persisted admin Chat on RubyLLM with continuation admission. Blocks Public Preview |
| Early integration proof exit gate | Open | Needs the Chat continuation half (RAA-0251/0252) |
| Phase 2 security regressions (RAA-0210) | Open | CSRF, mass assignment, XSS and N+1 regressions across list and Surface routes |
| Framework I18n | Open | Engine strings are English literals |
| Accessibility pass | Partial | Keyboard and 320px Chromium checks for some pages; no screen-reader pass; associations not yet checked |
| Remote CI on the release commit | Required per release | Last remote run: commit 69b4147 |
| Listed limitations in release notes | Required | Must name CSV, files, dashboards, Chat limits and P1 gaps |
| Owner approval and publishing | Owner only | `allowed_push_host` blocks `gem push` today |

**Verdict:** not ready for Public Preview. The blocking product gap is the admin
Chat entry and the early-proof gate behind it. The Phase 2 security, I18n and
accessibility evidence should close in parallel.

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
   - a `## X.Y.Z (YYYY-MM-DD)` section in `CHANGELOG.md` holding the former
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

   `release:check` must report no errors. For a release version it fails until
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
