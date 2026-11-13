# Changelog

## Unreleased

- `bin/demo --showcase` adds articles, tags and summaries to the demo host with
  every everyday field type, uploads, rich text, history, CSV export and bulk
  delete. `json` and `rich_text` fields stay off list pages unless declared
  `index: true`. The selection page no longer shows raw record versions, and
  rich-text and many-to-many inputs are named by their visible label instead of
  a `<label for>` that pointed at a non-form element.
- Search everything: a header search box (shown when the actor may search at
  least one menu resource) opens `<admin>/search`, which runs each resource's own
  list search and shows up to five records per resource through their show
  grants. **Breaking:** `search` is now a reserved resource key.
- The overview shows record counts for resources whose list opts into exact
  counts, with the list's bound. Dark mode already follows the system setting.
- Associations: `has_one :profile` shows a record's single child as a panel,
  with the same grants as `has_many` panels. A `references :tags` field edits a
  `has_many`/`:through`/HABTM list through `tag_ids=`: checkboxes for up to 100
  visible targets (a search picker beyond), only currently visible targets may be
  added, hidden stored targets are always kept, a changed list touches the record
  so its version advances and the audit names the field, and CSV, Chat and show
  pages label targets through their own grants.
- Rich text: a `rich_text` field edits a `has_rich_text` attribute with Trix from
  the host's Action Text assets (loaded only on forms that need it; file
  attachments refused). Show pages sanitize the stored HTML; lists, CSV and
  Chat use plain text; audit names the field when the content changes.
- File uploads: a `file` field for a `has_one_attached` attachment, with
  `accept:` content types and `max_size:` (default 10 MB). Uploads become new
  blobs only for fields the actor may write; the Runner accepts only new,
  unattached blobs that fit; refused writes purge them; a remove box clears an
  optional file; audit names the field. Downloads go through
  `<admin>/<resource>/<id>/files/<field>` with the record's scope, show grant
  and field read grant, streamed with a sandboxed CSP; only raster images show
  inline. Form recovery skips chosen files instead of failing.
- Bulk delete: a fixed selection offers "Delete the N selected records" when the
  resource allows `destroy` and the actor may delete at least one of them. After
  a review page, each record is deleted on its own through the native destroy
  operation (own policy check, version, transaction and audit); records that
  cannot be deleted are kept and listed with the reason. A changed selection
  deletes nothing. `Selections::Builder#revalidate` now yields current records
  to a block.
- CSV export: a default-deny `export_records?(context:, resource:)` grant (Pundit:
  `export_records?`) adds an Export CSV button that POSTs the current search,
  list tab, filters and sort to `<admin>/<resource>/exports`. Rows and columns
  follow the index, show and read grants; references export their labels;
  formula-like text is neutralized; `config.export_limit` (default 10,000)
  bounds a file, and each export is audited.
- Record History: with a new default-deny `view_history?(context:, resource:,
  record:)` grant (Pundit: `view_history?`), a record's page links to
  `<admin>/<resource>/<id>/history`, its audit trail newest first (50 per
  page): time, change, changed fields named only when currently readable or
  writable, actor and origin. Rejected writes now record their target, so a
  lost edit appears as "Not saved". A context adapter may answer
  `actor_labels(context:, actor_refs:)` to show names. New engine migration
  `add_record_index_to_rails_ai_admin_audit_events`.
- New field types: `time` (time of day), `email` (mailto link), `url` (only
  http/https addresses become links), `json` (indented editing and display on
  json/jsonb columns) and write-only `password` for `has_secure_password`. No
  read grant reveals a password; an empty box keeps the current one; audit
  names the field; input digests store a keyed hash of it. Schema suggestions
  offer `email`, `url`, `time` and `json` from column types and names.
  **Breaking:** a registered field type named `email`, `url`, `time`, `json` or
  `password` must be renamed, because those keys are now built in.
- Models no longer need a `lock_version` column. Without one, `updated_at`
  carries the record version (whole microseconds), compared after a row-locked
  load inside the write transaction; forms, intents, selections, collection
  items and Work delivery all use it. `updated_at` then cannot be a writable
  field, and doctor reports `version=lock_version`, `version=updated_at` or
  `version=missing` instead of `lock_version=true/false`.
- Framework I18n: every page heading, button, notice, status page, field
  validation message, Chat message and script message reads
  `config/locales/en.yml` (`rails_ai_admin.*`), and `<html lang>` follows
  `I18n.locale`. A new Translations guide shows how to add a locale. The
  English text is unchanged, except that the collection job backlog hint now
  renders the queue name as code instead of escaped `<code>` text. Host
  layout overrides keep working; their script messages stay English until
  they add `data-raa-messages` to `<body>`.
- Security regression sweep (RAA-0210): every state-changing engine route,
  including Surface and Chat routes, rejects a missing CSRF token without a
  side effect; unwritable, framework and tenant attributes are never mass
  assigned; record text and request values are escaped on every page; list
  and selection pages keep a constant query count as rows grow.
- Reference inputs past 100 targets keep the typed key input and add a search
  box that fills it. `GET <admin>/<target>/references/search?q=` returns at
  most 20 `{id, label}` results through the target's own policy relation,
  search grants and per-record show grant, plus an exact key match; filters
  use the same picker (RAA-030).
- Dependencies are on their latest releases: minitest 6.1.0, prism 2.1.0,
  Bundler 4.0.24, jekyll-vitepress-theme 1.12.0, Host B esbuild 0.28.2, and
  CI on ruby/setup-ruby v1.338.0 and Node 26. Ruby 4.0.9 and Rails 8.1.4.1
  were already current; the Rails 8.0 lock stays on 8.0.5.2 and json 2.x.
- Admin Chat runs on RubyLLM 2.2.0 and now requires it (`>= 2.2.0, < 3`).
  RubyLLM 2.2 broke Chat on the old 2.1 schema: a new
  `upgrade_rails_ai_admin_assistant_to_ruby_llm_2_2` migration adds its claim,
  phase, provider call id and usage columns and its queued-message and
  chat-file tables, skipping what a host already has. The provider context is
  bound before a turn's message is saved, since RubyLLM 2.2 builds its chat
  then, and usage ownership uses `RubyLLM.with_owner`.
- `bin/demo` copies the packaged session/SQLite host to `tmp/demo`, seeds it
  and serves it on 127.0.0.1 until Ctrl-C; `--assistant` adds admin Chat and a
  review Surface against an offline fake provider in `script/demo`.
- Schema suggestions and doctor's sensitivity check treat `admin` and
  `superuser` name parts as authority, so `users.admin` is no longer offered
  as an editable field.
- A ten-minute quickstart guide goes from a Rails 8 app with the
  authentication generator to a working Users admin, then to editing. The
  generated `AdminContext` and `AdminPolicyAdapter` stay closed but carry a
  commented, working example for that kind of app.
- `rails_ai_admin:resource Model --fields name:text points` writes the named
  schema suggestions as active (still readonly) fields, titles the resource by
  the first text field, and refuses a field the schema would not suggest or a
  type that differs from it.
- Generator output links the guides in the source repository instead of
  local `docs/` paths the gem does not ship, and the Chat generator names the
  supported ruby_llm range. The overview no longer calls Chat, Surfaces and
  associations later milestones (RAA-026).
- Support Ruby 3.3+ and Rails 8.0.5.2+ (was Ruby 4.0.9+ and Rails 8.1.4.1+).
  A CI compatibility job runs the engine suite on Ruby 3.3 and 4.0 with Rails
  8.0 and 8.1, on SQLite and PostgreSQL. Engine migrations declare
  `Migration[8.0]` (the same schema on 8.1); `json >= 2.13` is a dependency so
  override headers reject duplicate keys on json 2.x too; doctor reports a
  Rails 8.1 below the patched 8.1.4.1.
- The install and assistant generators keep an engine migration the host
  already has, even with `--force`. Rails would otherwise remove a changed
  one and copy it under a new timestamp, so an already-run migration ran
  again.
- `ruby_llm` and `rails_tool_views` are no longer runtime dependencies, so a
  conventional install pulls no AI code. Hosts that enable `config.assistant`
  or `config.surfaces` add the gem themselves; boot checks the supported range
  (`Configuration::OPTIONAL_GEMS`) (RAA-026).
- Make daily use pleasant (audit 2026-11-10). Model validation messages reach
  the page for writable fields (`config.validation_messages = :generic` keeps
  "is invalid"), and a field type's `valid?` may return a message (RAA-011).
  Timestamps use a native `datetime-local` input in the context zone and display
  as "30 Oct 2026 01:30 UTC" inside `<time>`; an unchanged save keeps stored
  fractions of a second; long text keeps line breaks (RAA-015). Required fields
  carry `required`, `aria-required` and a marker; readonly values are no longer
  `<output>` live regions (RAA-023). Pages have specific titles and headings,
  Cancel on edit returns to the record, the fixed "Development preview" became
  `config.environment_label`, a `session_links` partial holds the signed-in
  user, and a signed-out page visit redirects to `authentication_path` with
  `return_to` (RAA-024). Lists put search beside the heading, fold filters into
  `<details>`, add a page select-all and an Edit link per row (RAA-025). Codes
  become sentences on forms, failure pages and job tables (RAA-027). Search is
  trimmed and states its match mode; doctor names the fields it counts and gives
  index advice that matches the SQL (RAA-021, RAA-026). Empty values sort last
  (RAA-028); the collection review uses labels and formatting (RAA-029); only
  canonical ids address a record (RAA-022); `/jobs` follows its menu grant
  (RAA-030). Strings touched here moved to `config/locales/en.yml`.
- Make the assistant more trustworthy (audit 2026-11-10, partial). Searches
  cover the whole policy relation unless the model names a granted scope, and
  accept `sort`/`direction`; every result reports `applied_scope` and
  `applied_sort`, and `describe_resource` lists scopes, sortable fields and each
  search field's match mode (RAA-007, RAA-021). A new `count_records` tool
  answers "how many" with the capped index count. Tool values are typed JSON
  (null, booleans, integers, exact decimals, ISO times, `{value, label}`
  selects, `{id, label, resource}` references); `PROMPT_VERSION` is 2
  (RAA-017). Retryable provider failures schedule their own retry and the chat
  shows "Retrying (n of 3)" (RAA-008). Activity lines come from the stored
  tool result (RAA-018). A short assistant note precedes a new message after
  an unanswered one (RAA-030). `config.assistant_daily_message_limit`
  (default 100 per actor per 24 hours) is the minimal spend guard.
  Review Surfaces show the proposed visible changes, offer **Dismiss** (which
  expires the intent and tells the chat once), return to the chat after either
  action, and get rails_tool_views' Stimulus controller from the admin bundle
  (RAA-019).
- Unbreak ordinary flows (audit 2026-11-10). A list page leaves out an in-scope
  row whose `show` is denied and says so instead of returning 404 for the whole
  page; `TestKit.assert_scope_matches_show` finds the disagreement (RAA-001). An
  association panel's "View all" link carries the new `scope=_none` list state so
  the child's default tab no longer hides children the panel showed (RAA-006).
  "Capture selection" with nothing ticked returns to the list with a notice,
  duplicate ids collapse, and the button stays disabled until a row is ticked
  (RAA-013). A delete blocked by a foreign key or `restrict_with_error` returns
  the new `RESTRICTED` code with the model's reason instead of "Conflict… open a
  fresh form" (RAA-012). Form pages no longer write: they issue a signed form
  reference that becomes the intent on first submit or recovery, and
  `rails_ai_admin:prune` removes expired unused intents and selections (RAA-005,
  ADR 0025). Boot and doctor report a rails_tool_views `parent_controller` that
  does not resolve when Surfaces are on (RAA-009). Job pages say when work is
  waiting for a worker, doctor reports a backlog, and `config.queue_name`
  makes the `rails_ai_admin` queue name configurable (RAA-020). Error summaries use
  a sentence per result code with the code as secondary text.
- Stop silent data changes from conventional forms (audit 2026-11-10):
  blank or whitespace-only text is stored as null in a nullable field and
  rejected with "cannot be blank" when the field is `required` or
  `nullable: false` (RAA-002, RAA-003); decimals honour the column's precision
  and scale, or new `precision:`/`scale:` options, reject extra digits instead
  of rounding and display padded to the scale (RAA-004, RAA-014); impossible
  date-times such as `2026-02-30T10:00` are rejected (RAA-010); NUL and other
  control characters are rejected in text input, with tab and line breaks
  still allowed in `textarea` (RAA-016). The admin layout disables Turbo hover
  prefetch so hovering a link no longer prepares an intent (RAA-005).
  `required: true` now also rejects a null value.
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
