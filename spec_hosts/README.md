# Packaged consumers

`session_sqlite/` is an independent minimal Rails Host with native cookie-session
authentication, BCrypt, a custom policy, Propshaft and a separate importmap.
It is copied to ignored `tmp/`, then consumes the built gem through RubyGems
installation. It never uses a repository path dependency or the dummy app.

Run `bundle exec rake build`, then `bundle exec ruby script/packaged_smoke.rb`.
The test data, login credentials and secret key are synthetic fixtures only.
Do not deploy this host. The script starts no server and calls no provider.

`devise_postgres/` is a distinct support application with Devise sessions, explicit
Pundit policies, verified tenant memberships and UUID tickets. It already has its
own product RubyLLM Chat/Message and rails_tool_views Surface. Admin CRUD must
preserve them. Its real jsbundling build runs with either Propshaft or Sprockets;
those are variants of Host B, not additional independent applications.

After building the gem, set `RAA_HOST_B_DATABASE_URL` to a disposable PostgreSQL
database URL whose simple database name ends in `_test`. The scripts reject query
strings and fragments, then create and delete synthetic fixture records. For
credentials, load an environment file through your shell's normal secure process;
do not put a real password in command arguments or an inline export.

```sh
bundle exec ruby script/packaged_support_smoke.rb
bundle exec ruby script/packaged_recovery_smoke.rb
RAA_ASSET_PIPELINE=sprockets bundle exec ruby script/packaged_support_smoke.rb
```

The first script installs the actual built gem and released SDK migrations in
`tmp/packaged-devise-postgres`, checks the generated context is closed, then restores
the reviewed host adapter. It reruns the rails_tool_views 1.0.2 installer and verifies unchanged custom SDK
mount source and named path, without restoring routes afterwards. Host configuration
still belongs to the reviewed product initializer. DEP-001 and DEP-006 are resolved;
see `docs/reference/dependency-contracts.md` for the shared-runtime contract.

The recovery script edits/restores only the copied host sources, reloads Rails,
retries after committed response loss, and kills/reaps its own confirmed live child
inside a transaction. It leaves no server or child running. Both hosts use only
synthetic credentials and records; do not deploy them. No provider key/call is used.

The native-session host also exercises a confirmed member points award through a
custom adapter. Host B exercises an input-bound ticket review with Pundit, then
fresh job membership/epoch checks and tenant isolation. Its synthetic downstream
is an exclusive file receipt, never mail or HTTP. The recovery script abruptly
exits real workers before/after that effect, waits for actual five-second leases
to expire and verifies safe idempotent retry or non-idempotent reconciliation.
Stable-key request counts, one applied receipt and one business audit are checked.
This is local process-loss evidence; no real provider/delivery or host scheduler
reliability is established.

Both consumers execute the install-generated anonymous HTTP test at their actual
custom mount, and run host-owned TestKit role/field-grant matrices. They generate
an unregistered readonly resource for a user model and verify that schema advice
stays commented and omits sensitive authority/authentication columns. Host B draws
its admin mount from `config/routes/admin.rb`; installation must preserve it rather
than insert a second root-file mount.

Both hosts also grant Selection capture independently from list/write permission.
Native checkbox POST/CSRF captures fixed IDs/current versions and redirects to a
fresh-label preview. Tests revoke the host selection grant and verify denial;
Host B retains its UUID identity. Capture creates no business run or audit and
does not exercise collection execution or jobs.

The legacy-admin migration host and independent user/security acceptance remain
required. These author-controlled fixtures do not close release gates.
