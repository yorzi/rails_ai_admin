# Dependency integration boundaries

This record distinguishes selected package contracts, unresolved integration
constraints and verified defects. The current work establishes **no newly confirmed
upstream gem defect**. A local admin bug caused by an assumed dependency behavior
is not automatically a bug in that dependency.

| Dependency line | Current consumption boundary |
| --- | --- |
| Rails `>= 8.1.4, < 8.2` | Isolated engine, Active Record, controller/view/job infrastructure |
| rails_tool_views `~> 1.0.1` | Installed dependency; admin Surface/continuation runtime not integrated |
| RubyLLM `>= 2.1.1, < 3` | Installed dependency; no admin chats, provider configuration or calls |
| turbo-rails `~> 2.0`, stimulus-rails `~> 1.3` | Bounded Rails integration dependencies; admin ships prebuilt frontend |

The lockfile and `COMPATIBILITY.md` identify actual resolved/tested combinations.
Version ranges do not establish compatibility with future releases. Ordinary
installation must work without AI tables, provider keys or model catalog refresh.

## rails_tool_views coexistence constraint

The published 1.0.1 package uses process-level `configuration` and `registry`
objects. `scope_resolver`, `parent_controller`, `agent_adapter` and `auto_deliver`
are shared settings. `rails_tool_views_action_form` builds action URLs through the
dependency engine's route proxy. If admin overwrote these settings, a host's
existing product Surface could resolve a different identity or delivery adapter.

This is a confirmed design/integration constraint, not an established upstream
defect. The current admin does not overwrite those globals and has no Surface write
routes. SPIKE-03/06 must prove compatible ownership, namespaced actor/tenant refs,
component keys, dispatch routes and continuation before support is claimed.
Do not infer adapter stability from the dependency core's stable version.

Owning sources in the released package:

- [Configuration and registry](https://github.com/yorzi/rails_tool_views/blob/v1.0.1/lib/rails_tool_views/core.rb).
- [Action-form route construction](https://github.com/yorzi/rails_tool_views/blob/v1.0.1/app/helpers/rails_tool_views/surfaces_helper.rb).
- [Public contract](https://github.com/yorzi/rails_tool_views/blob/v1.0.1/docs/site/_reference/public-contract.md).

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

## RubyLLM isolation remains a later proof

The selected released RubyLLM package's Railtie installs Active Record support,
inflection and default instrumentation/accounting hooks when loaded in a Rails
process. Source inspection alone does not prove a collision in a real host.
Future admin Chat/Message/ToolCall tables must remain separate from host product
conversations, and provider settings must use a verified released isolation API.
Unreleased main-branch queue/claim/approval behavior is not an accepted dependency
of this slice. No paid-provider or durable-continuation evidence is claimed.

Owning source: [RubyLLM 2.1.1 Railtie](https://github.com/crmne/ruby_llm/blob/v2.1.1/lib/ruby_llm/railtie.rb).

## Frontend policy contract

Turbo creates an inline stylesheet for its progress bar. A strict CSP therefore
needs a correctly scoped nonce/hash even when the main JS bundle is external. The
admin supplies a per-response style nonce plus `csp-nonce` meta tag; it does not
add `unsafe-inline`. Host pipeline/CSP browser acceptance is still separate from
building the asset file. This is an integration requirement, not a Turbo defect.
