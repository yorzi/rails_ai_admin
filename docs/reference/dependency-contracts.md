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
| RubyLLM `>= 2.1.1, < 3` | Opt-in admin Chat on Engine-owned tables with `acts_as_chat`/`acts_as_message`, a per-request `RubyLLM.context` and shared ToolCall/Usage tables (ADR 0022); offline fixtures only, no live provider call |
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

## Rails callback integration hazards

The runner must inspect the actual persistence outcome when a callback aborts or
raises `ActiveRecord::Rollback`. Conversely, an `after_commit` exception can occur
after the domain write, receipt and successful audit are durable. Returning ordinary
validation failure in that case is incorrect. Current code guards rollback outcomes
and retains a committed receipt with a separate post-commit warning.

These were admin integration defects covered by regressions, not newly established
Rails defects. The admin also explicitly parses integer strings in base ten and
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
of this slice. Admin Chat's turn inbox, fencing and continuation have offline evidence through RubyLLM's real OpenAI provider and tool loop against WebMock and a loopback fixture (ADR 0022). No paid-provider evidence is claimed.

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

## Isolate route-inspection probes

Rails 8.1.4 shares mounted-helper definitions across route sets. Mounting a live
Engine in a fake route set before the real application's lazy routes are drawn
can leave its mounted proxy bound to the fake prefix. Our installer probes draw
the real host first and isolate the engine route set used by fake applications.
They do not mutate Rails private helper modules. Packaged hosts exercise the
actual mount and real development reload separately. This is an integration/test
constraint, not a claim that supported one-host mounting is broken or that
multiple independent hosts/mounts in one process are supported.
