# Releasing

0.2.0 is the current Public Preview release. The owner authorized its publication
on 2026-11-14 with “release 0.2.0”. The release commit opens `allowed_push_host`;
the main branch has reopened as `0.3.0.dev` with publishing blocked.

## Candidate checks

Run these against the candidate, using disposable PostgreSQL databases:

```sh
bundle exec rubocop --cache false
bundle exec rake test
RAA_TEST_DATABASE_URL=postgresql://…/raa_test bundle exec rake test
npm ci --prefix frontend
npm run check --prefix frontend
bundle exec rake build
bundle exec ruby script/packaged_quickstart_smoke.rb
bundle exec ruby script/packaged_smoke.rb
RAA_HOST_B_DATABASE_URL=postgresql://…/raa_host_b_test bundle exec ruby script/packaged_support_smoke.rb
RAA_HOST_B_DATABASE_URL=postgresql://…/raa_host_b_test RAA_ASSET_PIPELINE=sprockets bundle exec ruby script/packaged_support_smoke.rb
RAA_HOST_B_DATABASE_URL=postgresql://…/raa_host_b_test bundle exec ruby script/packaged_recovery_smoke.rb
RAA_HOST_B_DATABASE_URL=postgresql://…/raa_host_b_test bundle exec ruby script/packaged_collection_recovery_smoke.rb
docs/site/bin/build.sh
bundle exec rake release:check_candidate
```

CI also covers the engine on Ruby 3.3 and both databases, asset reproducibility,
Ruby dependency advisories and npm advisories. Record executed combinations in
`COMPATIBILITY.md`; local results do not establish that remote CI passed. The
candidate check accepts a closed publishing gate and never publishes.

Before approval, review generated resource exposure, tenant policies and the
upgrade guide. A human screen-reader pass, independent host trial and current live
provider checks remain open. Offline provider tests do not replace live evidence.
Association sorting, nested child forms, polymorphic writes, separate attach/detach
grants, conversation retention and token/cost budgets remain outside this release.

## After owner approval

1. Synchronize the final version in `lib/rails_ai_admin/version.rb`, `Gemfile.lock`,
   both `spec_hosts/*/Gemfile` pins and `docs/site/_config.yml`. Set `released: true`,
   date the versioned changelog section and update release history and upgrade notes.
2. Open `allowed_push_host` to `https://rubygems.org` only in the approved release
   commit. Build and run `release:check`, then push for CI. Merge only after the
   exact commit passes. No publishing is performed by the ordinary CI workflow.
3. Create the signed version tag on the reviewed commit, wait for tag CI, and
   rebuild deterministically with `SOURCE_DATE_EPOCH` set to the commit timestamp.
   Record the SHA-256 of that exact package.
4. Dispatch **Publish gem** from `main`, supplying the tag, full tested commit
   SHA and package SHA-256. Its default `publish: false` verifies the package only.
   Enable publishing only with owner approval; the workflow uses RubyGems Trusted
   Publishing and the protected `release` environment.
5. Create the GitHub release with notes and the digest. Publishing the GitHub
   release triggers **Publish documentation**. Verify the live version, install
   command, `/next/` and API reference after deployment.
6. Reopen development with the next `.dev` version, `released: false`, an
   `Unreleased` changelog and the blocked push host.

Never publish from a dirty checkout, an unreviewed tag or a package whose digest
differs from the reviewed build. A green check is evidence, not owner approval.
