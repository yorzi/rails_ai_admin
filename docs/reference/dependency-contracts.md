# Dependency integration boundaries

This record distinguishes selected package contracts, unresolved integration
constraints and resolved reports. The selected rails_tool_views 1.0.2 fixes the
previous custom-mount installer defect and clarifies its host-owned shared runtime.
DEP-001 and DEP-006 are closed; full admin Surface/continuation acceptance remains
future product work. Local admin mistakes are not upstream defects.

| Dependency line | Current consumption boundary |
| --- | --- |
| Rails `>= 8.1.4, < 8.2` | Isolated engine, Active Record, controller/view/job infrastructure |
| rails_tool_views `~> 1.0.2` | Opt-in admin review Surface through admin-owned endpoints and the public API (ADR 0020); assistant proposals present it and continue through the admin inbox, not `deliver` (ADR 0022) |
| RubyLLM `>= 2.1.1, < 3` | Opt-in admin Chat on Engine-owned tables with `acts_as_chat`/`acts_as_message`, a per-request `RubyLLM.context` and shared ToolCall/Usage tables (ADR 0022); offline fixtures, plus one live run per model family through the OpenRouter provider on 2026-11-03 |
| Pundit 2.5.x / Devise 5.0.4 | Optional host authorization/authentication examples; not runtime requirements |
| turbo-rails `~> 2.0`, stimulus-rails `~> 1.3` | Bounded Rails integration dependencies; admin ships prebuilt frontend |

The lockfile and `COMPATIBILITY.md` identify actual resolved/tested combinations.
Version ranges do not establish compatibility with future releases. Ordinary
installation must work without AI tables, provider keys or model catalog refresh.

## Resolved rails_tool_views reports

| Report | Resolution in 1.0.2 |
| --- | --- |
| DEP-001: shared runtime ownership | Configuration guide explicitly requires one host-owned configuration/registry/mount. Gems register distinct component keys and leave host authority/delivery settings alone. Closed as a documented integration contract. |
| DEP-006: duplicated existing mount | Installer skips an existing root-file Engine mount. The packaged consumer checks unchanged route source and the existing named path without restoring the file afterwards. |

There is still one process-level runtime. This release does not add isolated
configurations or change the action helper's named `rails_tool_views` route.
The admin leaves those globals untouched. Its opt-in `raa_operation_review`
component uses admin-owned endpoints with an explicit Scope, reuses only the
public `rails_tool_views_action_fields` helper, and re-registers after a host
`reset_registry!`. No upstream change was needed for this; the custom action URL
option suggested in plan §6.3.1 remains unrequested. Continuation and PresentUI
integration remain open.

### Admin continuation does not use `deliver`

In 1.0.2, `dispatch` creates an AgentInteraction as `pending` only when the
process-wide `agent_adapter` is set and as `skipped` otherwise, and `deliver`
returns without calling any adapter for a skipped interaction. An explicit
`deliver(id, scope:, adapter:)` therefore cannot deliver an admin interaction on
a host with no global adapter, and on a host with one the interaction belongs to
the host's delivery path. The admin returns `agent: false` from its confirm
handler and instead admits a continuation turn into its own inbox inside the
same Surface transaction (ADR 0022). This is a recorded integration constraint,
not a reported defect; a per-call adapter or status option would let a future
release use `deliver` without host globals.

Owning released sources:

- [Shared runtime configuration](https://github.com/yorzi/rails_tool_views/blob/v1.0.2/docs/site/_getting_started/configuration.md#share-one-runtime).
- [Configuration and registry](https://github.com/yorzi/rails_tool_views/blob/v1.0.2/lib/rails_tool_views/core.rb).
- [Action-form route construction](https://github.com/yorzi/rails_tool_views/blob/v1.0.2/app/helpers/rails_tool_views/surfaces_helper.rb).
- [Installer](https://github.com/yorzi/rails_tool_views/blob/v1.0.2/lib/generators/rails_tool_views/install/install_generator.rb).

## Open integration findings

Issues met while integrating the released packages. Each was checked against the
released source; none is patched, monkey patched or forked here. "Worked around"
means the admin uses public APIs only and the workaround is covered by tests.
Suggested upstream changes are minimal and backward compatible; none has been
filed yet.

| ID | Package | Finding | Status and workaround | Suggested upstream change |
| --- | --- | --- | --- | --- |
| DEP-008 | rails_tool_views 1.0.2 | `reset_registry!` replaces the whole process registry and there is no `registered?`, replace or unregister API. A host `to_prepare` reset (the documented reload pattern) runs after an engine's `to_prepare` and silently removes gem components registered there. | Worked around: `raa_operation_review` has a constant contract and registers lazily and idempotently before each use; an existing key must carry the admin's own policy/handler objects (squatting is an error). Host B reload probe covers it. | Owner- or prefix-scoped registration that survives a host reset, or `reset_registry!(except:)`/`register(..., if_absent:)` returning the existing component. |
| DEP-009 | rails_tool_views 1.0.2 | Component policies and handlers receive only the frozen `Access` (actor/tenant strings, operation, props, action, arguments, context_ref). `present`/`restore`/`dispatch`/`render` cannot pass request-scoped host authority, so a policy cannot re-check the host's real current grants without process state. | Worked around: admin endpoints bind the current admin Context in `ActiveSupport::IsolatedExecutionState` for one call; policy and handler deny when it is absent or does not match the Scope exactly. | An optional opaque `authority:` keyword on those calls, threaded into `Access` and never persisted. |
| DEP-010 | rails_tool_views 1.0.2 | `rails_tool_views_action_form` always posts to the engine mounted as `rails_tool_views` (authenticated by the global resolver); there is no `url:` option. Known from plan §6.3.1. | Worked around: admin forms reuse the public `rails_tool_views_action_fields` with the admin endpoint URL. | `url:` option on `rails_tool_views_action_form`/`_button`. |
| DEP-011 | rails_tool_views 1.0.2 | A correlated `present` replays only when the new request digest (component, props, context) matches; there is no public lookup of an existing correlated presentation. An adapter whose props embed a server-generated value (such as an intent id) cannot replay a crashed tool call without reproducing those props exactly. | Worked around: the assistant proposal derives one UUIDv5 intent per (actor, tenant, conversation, tool call) and re-coerces the same arguments, so replays present identical props. | `RailsToolViews.correlated_surface(adapter:, call_id:, context:, scope:)` returning the existing Surface or nil. |
| DEP-013 | rails_tool_views 1.0.2 | **Blocking for shared-mode continuation.** `dispatch` creates the follow-up `AgentInteraction` as `pending` only when the host's *global* `configuration.agent_adapter` is set (`runtime.rb` line 73), otherwise `skipped`; `deliver` treats `skipped` as terminal (line 113). So `deliver(id, scope:, adapter:)` with an explicit admin adapter (plan §6.3.1 item 4) never runs in a host that, like Host B, sets no global adapter, and setting one would change host-owned behavior. | SDK limitation remains open. `test/integration/tool_views_continuation_contract_test.rb` characterizes both cases; admin Chat uses its own transactionally admitted continuation inbox (ADR 0022), without changing host globals. Historical alternatives are in ADR 0024. | Create follow-ups as `pending` whenever a transition asks for one (the existing `AGENT_NOT_CONFIGURED` path already keeps work non-terminal when no adapter is available), or accept `Transition.new(agent: :explicit)` meaning "delivered by an explicit adapter". |
| DEP-012 | rails_tool_views 1.0.2 | `RailsToolViews.render(surface, view_context:)` renders `rails_tool_views/surfaces/surface`, which calls `RailsToolViews::SurfacesHelper` methods, but does not add that helper; a host or engine controller that is not the gem's own must include it. | Worked around: the admin extends only the rendering view instance with the helper. | Document the requirement, or include the helper in the render path. |

RubyLLM 2.1.1 integration for assistant proposals (ADR 0023) found no defect.
Two consumption notes: tests build `RubyLLM::ToolCall` directly to exercise the
tool contract, and that constructor is marked `:nodoc:` (production code only
receives instances from a chat), so a RubyLLM upgrade must rerun those tests.
The OpenAI provider defaults to the Responses protocol; the offline loop selects
`protocol: :chat_completions` explicitly, so Responses-protocol behavior is not
yet covered.

Development-tool updates (2026-11-01), also not defects: Minitest 6.0 moved
`minitest/mock` (`Mock`, `Object#stub`) into the `minitest-mock` gem and rejects
nil-expecting `assert_equal`; the suite adds `minitest-mock` and the packaged
hosts' `~> 5.27` pins move to `~> 6.0` (Dependabot's single-file bump failed CI
for both reasons). esbuild 0.28.2 changes the minified prebuilt bundle bytes, so
the reproducible asset check needs a rebuild with each esbuild bump; Turbo and
Stimulus versions are unchanged and the packaged-host browser flows were
rechecked.

Consumption rules that are documented upstream behavior, not defects: action
handlers run inside the Surface row lock, so the admin Runner's
`requires_new` transaction becomes a savepoint and commits with the Surface
revision; `deliver` refuses to run inside an open transaction and must be called
after commit.

## Rails callback integration hazards

The runner must inspect the actual persistence outcome when a callback aborts or
raises `ActiveRecord::Rollback`. Conversely, an `after_commit` exception can occur
after the domain write, receipt and successful audit are durable. Returning ordinary
validation failure in that case is incorrect. Current code guards rollback outcomes
and retains a committed receipt with a separate post-commit warning.

These were admin integration defects covered by regressions, not newly established
Rails defects. The same applies to per-form CSRF tokens (Rails default since 5.0):
a token is bound to its form's action URL, so a `formaction` button that submits
the same form to another route is rejected with 422. The admin review hand-off
originally did this; packaged Host B caught it and the button now has its own
form (ADR 0020). The CSRF-free engine dummy app cannot detect this class of bug,
which is why packaged hosts keep real CSRF. The admin also explicitly parses integer strings in base ten and
supplies a LIKE escape clause for SQLite literal wildcard searches; those behaviors
are adapter responsibilities.

## RubyLLM isolation

The selected released RubyLLM package's Railtie installs Active Record support,
inflection and default instrumentation/accounting hooks when loaded in a Rails
process. Source inspection alone does not prove a collision in a real host.
Future admin Chat/Message tables must remain separate from host product
conversations, and provider settings must use a verified released isolation API.

ToolCall and Usage rows are isolated per chat, not per table. The 2.1.1
`acts_as_message` macro maps those associations to RubyLLM's own
`ruby_llm_tool_calls` and `ruby_llm_usages` tables and has no `tool_call_class`
keyword; Host B public reflection confirmed both. That matches RubyLLM's ownership
model, where it owns supporting tables and applications own chats and messages, so
the admin adopts the shared tables instead of Engine-owned copies. The associations
are polymorphic, and chat-level lookups such as `pending_approvals` filter by the
message class's `polymorphic_name` and the chat's own message ids. A probe in
RubyLLM's dummy app with two chat/message pairs sharing the same ids kept tool
calls, pending approvals and usages apart and rejected a cross-chat `approve`.
Admin code reads these rows only through its own associations; do not change the
SDK's global table names or monkey patch private methods. The usage ledger is
shared, so pick the admin's usage owner deliberately. Unreleased main-branch queue/claim/approval behavior is not an accepted dependency
of this slice. Admin Chat's turn inbox, fencing and continuation have offline evidence through RubyLLM's real OpenAI provider and tool loop against WebMock and a loopback fixture (ADR 0022). One full flow per model family through OpenRouter is recorded in COMPATIBILITY.md (2026-11-03); native provider APIs and live failure recovery remain unverified.

Owning source: [RubyLLM 2.1.1 Railtie](https://github.com/crmne/ruby_llm/blob/v2.1.1/lib/ruby_llm/railtie.rb).
The [released persistence macros](https://github.com/crmne/ruby_llm/blob/v2.1.1/lib/ruby_llm/active_record/acts_as.rb)
and [Chat persistence](https://github.com/crmne/ruby_llm/blob/v2.1.1/lib/ruby_llm/active_record/chat_methods.rb)
own the shared ToolCall/Usage mapping and its polymorphic scoping.

## Frontend policy contract

Turbo creates an inline stylesheet for its progress bar. A strict CSP therefore
needs a correctly scoped nonce/hash even when the main JS bundle is external. The
admin supplies a per-response style nonce plus `csp-nonce` meta tag; it does not
add `unsafe-inline`. Host pipeline/CSP browser acceptance is still separate from
building the asset file. This is an integration requirement, not a Turbo defect.

## Preserve the reviewed host configuration

The 1.0.2 packaged smoke reruns the released installer with an existing custom
`RailsToolViews::Engine` mount in `config/routes.rb`. It asserts that route source
is unchanged and the named helper still resolves to `/product_surfaces`. No route
restoration or dependency patch hides an installer regression. This verifies the
original DEP-006 case; it does not claim support for every alternate Rails mount
spelling or generated route layout.

The installer still generates configuration scaffolding. The fixture retains its
reviewed host-owned product initializer instead of treating generated defaults as
an automatic merge. Admin Chat/Surface and continuation have their own remaining
acceptance gates.

## Rebuild assets when re-verifying a copied host

The packaged smoke runs a production `assets:precompile` inside the copied host.
Its `public/assets` then shadows a reinstalled gem's stylesheet in later manual
browser checks, so a CSS fix appears not to apply. Remove the copied host's
`public/assets` (or rerun the smoke) before re-verifying. This is a local
verification hazard, not a Propshaft defect.

## Isolate route-inspection probes

Rails 8.1.4 shares mounted-helper definitions across route sets. Mounting a live
Engine in a fake route set before the real application's lazy routes are drawn
can leave its mounted proxy bound to the fake prefix. Our installer probes draw
the real host first and isolate the engine route set used by fake applications.
They do not mutate Rails private helper modules. Packaged hosts exercise the
actual mount and real development reload separately. This is an integration/test
constraint, not a claim that supported one-host mounting is broken or that
multiple independent hosts/mounts in one process are supported.
