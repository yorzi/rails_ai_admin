# Changelog

## Unreleased

- Reconcile the association/Chat branch with remote main, retaining the standalone
  assistant proposal API and its explicit `assistant: true` opt-in. Admin Chat
  now honors that flag too; native Surface permission alone grants no proposal.
- Fence assistant message persistence atomically against the current turn lease,
  including late provider answers/tool calls and stale-worker cleanup. Recovery
  removes abandoned placeholders without dropping billed usage.
- Fix Chat search pagination independently of native page size; byte-truncated
  results return `next_offset` so omitted records remain reachable.
- Distinguish `.dev` builds from approved alpha/beta/RC versions in release checks;
  published prereleases need versioned changelog/docs metadata and owner approval.
- Pin packaged consumers to Rails 8.1.4.1, discard stale generated locks and
  verify installed candidate metadata and all files before acceptance. The
  release checker rejects host Rails pins below the runtime floor.
- Raise the Rails dependency floor to 8.1.4.1 and refresh affected Ruby lockfiles
  (Rails, Addressable, Loofah, Nokogiri and rails-html-sanitizer).

- Add opt-in admin Chat (`config.assistant`, ADR 0022). The
  `rails_ai_admin:assistant` generator adds Engine-owned chat, message and turn
  tables and a closed `AdminAssistant` adapter whose `llm_context(context:)`
  returns a per-request `RubyLLM::Context`; global RubyLLM settings are never
  read or changed, and conventional hosts load no RubyLLM code.
- Add the default-deny `assistant?(context:, resource:)` grant (Pundit:
  `assistant?`). Read tools (`list_resources`, `describe_resource`,
  `search_records`, `get_record`) apply every current grant and return bounded
  JSON with fixed error codes.
- Add `propose_operation`, which prepares an `origin: assistant` intent and
  shows the existing review Surface in the conversation. The human's Surface
  confirmation writes once and admits one continuation turn in the same
  transaction.
- Add a persistent per-chat turn inbox: keyed admission, strict ordering,
  leases with fencing, a once-only human message, reconciliation of an answer
  persisted before a crash, retry, Stop and archive, plus
  `rails_ai_admin:assistant:scan`/`drain`. Doctor reports the assistant setup
  without calling the adapter or a provider.
- Fix `describe_resource` omitting the allowed values of an operation's `enum`
  input. A live model guessed `triaged` for the triage `decision` and needed two
  rejected proposals before trying `triage`; it now receives the choices.

- Add `belongs_to` reference fields. A reference is labelled and linked only
  through the target resource's current relation, show grant and title, and an
  index loads each reference column with one query. Missing, foreign and hidden
  targets render the same `Customer #42` placeholder. Forms offer up to 100
  visible targets (else a typed key); the Runner rejects a changed reference the
  actor cannot see, keeps an unchanged one and maps a foreign-key race to
  CONFLICT. References filter by `eq`; they cannot search or sort yet.
- Add readonly `has_many` show-page panels read through the child resource's
  index grant, policy relation and a readable reference field, with a filtered
  "View all" link while that field is filter-granted.
- Add `Field#column`; reads, writes, list queries, audit field names and doctor
  checks now distinguish a field's name from its column. Doctor adds an
  `associations:<resource>` reflection check.
- Add the `field_reference` and `resource_associations` override entries
  (catalog now 29). **Review overrides:** `resource_show` advances to revision 3
  and `field_form` to revision 2.
- The resource generator suggests a declared non-polymorphic, non-sensitive
  `belongs_to` as a commented `belongs_to` field; tenant-like references
  (account, tenant, organization, workspace, company, team) and other key
  columns stay omitted.
- `rake build` names the package from `RailsAiAdmin::VERSION`, and
  `rake release:check` reports release readiness without publishing.

- Merge Dependabot updates after verification: actions/checkout 7.0.1 and
  actions/setup-node 7.1.0 (still SHA-pinned), jekyll-vitepress-theme 1.11.0,
  esbuild 0.28.2 (prebuilt bundle rebuilt) and Minitest 6.0.6. Minitest 6
  extracted `minitest/mock`, so `minitest-mock` is now a development dependency
  and the packaged hosts pin Minitest `~> 6.0`.
- Add assistant operation proposals: `operation ..., assistant: true` and the
  on-demand `Integrations::ProposeOperation` RubyLLM tool, which preflights an
  `assistant`-origin intent and presents the review Surface; only the human's
  Surface confirmation executes. Tool-call replays are idempotent.
- Record open rails_tool_views integration findings DEP-008..012.
- Add opt-in admin review Surfaces on the host-owned rails_tool_views runtime:
  `config.surfaces`, `operation ..., surface: true`, admin-owned endpoints with an
  explicit `raa:` Scope and a constant `raa_operation_review` component. A
  Surface confirms the same native intent once through the shared Runner;
  completed reviews need the receipt grant. Host settings are never changed.
- Add index table settings: declared columns, a default sort applied only while
  granted, page sizes of 1..100 and exact counts bounded at 10,000 (no
  tenant-global estimates). Cells no longer split words and compact values stay
  on one line, so wide tables scroll (resource_index revision 5).
- Add gemspec homepage and source/changelog/bug-tracker metadata.
- Add typed list filters: `filterable:` fields with eq/gte/lte by scalar type, a
  separate default-deny `:filter` field grant (Pundit `filterable_fields`),
  contract-coerced Arel-bound values, canonical nested filter list hints and a
  native filter form (resource_index revision 4). Doctor reviews unindexed
  filterable columns. **Breaking:** TestKit field snapshots and
  `assert_field_grants` now require a `filter` group.
- Update rack to 3.2.8 for GHSA-2j8w-xcrc-x985, GHSA-5v64-555j-wjxm,
  GHSA-p8x9-v4hv-2w4g and GHSA-wvg4-6p58-3gh3.
- Add named list scopes: bounded index tabs with an optional default that are
  intersected with the policy relation by primary key, need an independent
  default-deny `named_scopes` grant (Pundit `permitted_named_scopes`), travel in
  list hints and render as current-grant tabs (resource_index revision 3).
- Require Ruby 4.0.9 or newer; development, RuboCop and every CI job use the
  `.ruby-version` pin (4.0.9) instead of a Ruby 3.4/4.0 matrix.
- Establish the implementation baseline from the reviewed v0.3 development plan.
- Add an isolated, default-deny Engine with explicit resources and scalar fields.
- Add synchronous CRUD intents with identity/input/version/expiry binding, current
  authorization, atomic receipts/audit, replay protection and callback outcome checks.
- Add conventional pages, bounded search/sort, readonly resource aliases, prebuilt
  Turbo/Stimulus assets and request-local log redaction.
- Add closed installation/resource generators, basic doctor/TestKit, a packaged
  session/SQLite consumer, database contracts and local public documentation.
- Add the optional explicit Pundit adapter, a distinct packaged Devise/PostgreSQL
  host, Propshaft and Sprockets/jsbundling variants, real development reload and
  process crash/response-loss recovery probes. Keep host product SDK settings intact.
- Add schema-only commented field suggestions, preserved default-deny install
  scaffolds and actual-route preflight checks. Expand doctor metadata diagnostics
  and host TestKit policy/field-grant assertions; run generated anonymous tests in
  both packaged consumers.
- Add registered member Operations with typed pure preflight, native human
  confirmation, independent input/receipt authority and guarded versioned writes.
- Add atomic outbox intents, fresh delivery authority, bounded leases/fencing,
  stable request fingerprints, explicit unknown outcomes and pending-work scans.
  Keep delivery outcomes separate from committed business receipts.

- Restrict scalar projection and record titles to model attributes before invoking
  getters, preventing accidental mutating-method calls during readonly display.
  Normal attribute getter overrides remain trusted host code.

- Add immutable fixed selections with independent default-deny grants, canonical
  target/version manifests, native capture/preview and fresh revalidation.
- Bind operation/selection identity to the physical table and primary-key contract,
  preventing stale references from changing meaning after a model remapping.

- Add asynchronous fixed-manifest collection operations with one parent approval,
  current collection/record grants, leased item transactions, fenced receipts,
  bounded recovery, partial cancellation and native job/result controls.
- Select rails_tool_views 1.0.2, close DEP-001/DEP-006 and verify the released
  installer preserves an existing custom mount without route restoration.

- Add a reloadable scalar field-type registry with pure normalization/validation,
  intersected JSON Schemas, plain-text formatting and trusted field partials.
  Bind plugin versions/schema to operation, selection and Work fingerprints.
- Add fixed Select labels, a readonly scalar shorthand and disabled placeholders
  for unavailable selections. Respect per-record field denial before rendering.
- Accept typed Date/Time operation proposals during confirmation/replay without
  freezing caller-owned temporal values; preserve timestamp microseconds in hooks
  and native forms, and reject nonfinite decimals.
- Exercise custom fields in both packaged consumers and initialize domain fixture
  schema before transactional request tests so fresh databases are deterministic.

- Add bounded readonly computed fields with declared dependency graphs, recursive
  read grants, immutable scalar snapshots and fresh versioned host computations.
- Share cached row projections and formatted titles across pages, selections and
  jobs; block physical-getter writes and reject fabricated virtual previews.
- Verify graph/size/time bounds, dependency denial, current result projection,
  query counts, stale contracts and actual computation reload in packaged hosts.

- Add individual template overrides with a public catalog, deterministic source/
  context headers, exclusive Unicode-preserving copies and non-destructive reruns.
- Add bounded doctor diagnostics for stale/manual/invalid override metadata without
  evaluating ERB. Keep host-body review separate from source metadata agreement.
- Add independent new/edit wrappers for GET/validation/conflict and default field
  display partials; verify standard host view precedence and live template reload.

- Add per-view resource presentation masks, global hidden fields, plain help text
  and authorized readonly context in bounded tab/panel form plans. Keep write-only
  prefills blank and enforce fresh create/edit masks in the shared Runner.
- Add progressive keyboard tabs, native invalid-control revelation, error-summary
  focus/links and collision-free help/error IDs. Preserve hidden-panel FormData.
- Add the field-row override and advance changed form context revisions to 2.


- Preserve open generic forms on explicitly marked session/CSRF failures and add
  manual reauthentication recovery with a fresh CSRF form, current editable fields
  and the same unconsumed intent. Bound recovery to one hour and require Save.
- Keep snapshots in the open DOM only; preserve edits while recovery waits and
  reject stale/completed/foreign intents without reissuing or replaying a write.
- Add the recovery partial/host login-path setting, private response handshake and
  revision 3 new/edit/shared-form contracts. Verify actual Devise timeout recovery.

- Preserve structured resource list hints through CRUD, member review, selections
  and collection job controls without accepting arbitrary redirect URLs.
- Add authorized sortable headers, stable pagination/return links and bounded
  same-filter empty-page recovery. Revalidate stale settings with a visible fallback.
- Carry Unicode list hints through open-tab recovery using a bounded ASCII codec;
  retain the original business intent and fresh hidden security fields.
- Reject malformed search/page encodings and control searches before database
  serialization. Declare the already-resolved base64 codec as a direct dependency.

- Add public host CustomController entry points for current Context, scoped Access,
  shared Runner, mounted routes and layout CSP nonce without replacing host helpers.
- Add eight fixed minimal status kinds with HTML/Turbo reload, anti-enumeration,
  status-template plain fallback and two individual override catalog entries.
- Add packaged Order CRUD and a host-owned review workbench sharing the native
  operation/intent, plus real controller/operation reload and browser recovery proof.
- Return CONFLICT for unique-index rejection with full transaction rollback. Isolate
  temporary mounted-route probes so randomized tests use the real host prefix.

- Add static resource menu groups, plain labels, fixed decorative icons, ordering
  and `navigation false`, built per request from current index grants. Hiding a
  menu entry grants or revokes nothing and leaves approval/Selection identity intact.
- Add the resource_navigation partial (catalog now 27 entries) and advance the
  layout/dashboard contracts to revisions 3/2; legacy visible_resources is kept.
- Reject an unusable fallback menu label at registration instead of making every
  admin page unavailable at render time.

Assistant Chat, global actions, custom CRUD replacement, 10,000-target batch
materialization, association search/sort and writes beyond belongs_to, files, CSV
and metrics dashboards are not implemented. Release gates remain open.

No gem has been published.
