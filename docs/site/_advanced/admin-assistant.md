---
layout: default
title: Admin Assistant
nav_order: 9
description: Add an opt-in admin Chat that reads through current permissions and proposes changes as reviews the user confirms.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* How to install and enable admin Chat without touching your product's RubyLLM setup.
* Which grants expose resources to the model and which checks still apply.
* How a proposed change reaches the database exactly once.
* How turns recover after a crash, and what still needs real-provider checks.

## Understand the Boundary

The assistant answers questions about records the signed-in admin can already
open, and it can suggest a change to a record. It cannot change data itself. A
suggestion becomes the same review Surface that the native confirmation page
uses, and only the person's own confirmation in that review runs the operation.

Admin Chat is off by default. A conventional install loads no RubyLLM code,
creates no assistant tables and never calls a provider.

## Install

Add `ruby_llm` to your Gemfile and run the generator:

```sh
bin/rails generate rails_ai_admin:assistant
bin/rails db:migrate
```

The migration creates three Engine-owned tables: `rails_ai_admin_assistant_chats`,
`_messages` and `_turns`. Tool calls and token usage go into RubyLLM's own
`ruby_llm_tool_calls` and `ruby_llm_usages` tables. The migration creates those
only when your application has none yet. Admin rows never share records with
your product's conversations, even when ids are equal.

The generator also writes `app/rails_ai_admin/admin_assistant.rb`. It returns
`nil`, which keeps the assistant unavailable. Replace it with your provider
settings:

```ruby
class AdminAssistant
  def llm_context(context:)
    key = Rails.application.credentials.dig(:admin_assistant, :openai_api_key)
    return unless key

    RubyLLM.context do |config|
      config.openai_api_key = key
      config.request_timeout = 60
      config.max_retries = 1
    end
  end
end
```

The adapter receives the current admin `Context`, so per-tenant keys are
possible. Return `nil` whenever the assistant should be unavailable; the page
then explains that and the rest of the administration works as usual. Never
call `RubyLLM.configure` for the admin: the returned context keeps admin
settings separate from your product's.

## Enable It

```ruby
# config/initializers/rails_ai_admin.rb
RailsAiAdmin.configure do |config|
  config.assistant = true
  config.assistant_adapter = "AdminAssistant"
  config.assistant_model = "gpt-4.1-mini"
  config.assistant_provider = "openai"           # optional
  config.assistant_protocol = "chat_completions" # optional
  config.surfaces = true                          # for proposals
end
```

Boot fails when `ruby_llm` is not loaded. Proposals also need
[Review Surfaces](review-surfaces.html) and at least one member operation with
`surface: true`.

Assistant turns run in Active Job. Use a persistent queue and schedule recovery
for jobs lost in a crash:

```sh
bin/rails rails_ai_admin:assistant:scan   # enqueue chats with due turns
bin/rails rails_ai_admin:assistant:drain  # or run them inline
```

Your context adapter must implement `resolve_job(actor_ref:, tenant_ref:,
security_version:)`, as for collection operations. A worker uses it to rebuild
the chat owner's current authority for every turn.

## Grant Access

Each resource stays hidden from the model until your policy grants
`assistant?`. The Assistant menu entry and pages exist only for actors with at
least one exposed resource.

```ruby
class TicketPolicy
  def assistant? = %w[operator admin].include?(context.actor.role)
end
```

With a custom adapter, implement `assistant?(context:, resource:)`. The grant
only decides whether the model may see a resource. Every tool call still
applies the same index, show, read, search, filter and operation grants as the
native pages, so the model never receives a field or record the person could
not open. Another tenant's record and a missing record return the same
`NOT_FOUND` result.

## Know the Tools

| Tool | Returns |
| --- | --- |
| `list_resources` | Exposed resource keys and labels |
| `describe_resource` | Readable fields, searchable and filterable fields, and member operations that can be proposed |
| `search_records` | Up to 20 records per page through the shared list query, with text search and typed filters |
| `get_record` | One record's readable fields |
| `propose_operation` | A review Surface for one member operation (only with `config.surfaces`) |

Results are bounded JSON (16 KB). Errors carry only a fixed code such as
`NOT_FOUND`, `INVALID_QUERY` or `CONFLICT`, never a stack trace or SQL.

## Follow a Proposal

1. The model calls `propose_operation`. The admin authorizes the operation
   against the record, runs its preflight and saves an unconfirmed intent with
   origin `assistant`. Nothing in your data changes.
2. The conversation shows the review Surface. A retried tool call shows the
   same review rather than preparing another one.
3. The person confirms. In one transaction, the shared Runner writes the change,
   audit and receipt, the Surface records its new revision, and the chat
   receives one continuation turn describing the committed result.
4. The assistant replies to that result in the same conversation.

A repeated confirmation, or a confirmation on the native page first, writes
nothing twice and admits no second continuation. If the chat was archived in
the meantime, the confirmation still succeeds; only the follow-up is skipped.

## Recover From Failures

Sending a message saves it as a queued turn and returns at once; no provider
call runs in a web request. A worker claims the oldest turn of a chat under a
lease, so later messages wait their turn. The page refreshes while a turn is
pending and offers a Refresh link without JavaScript.

| Situation | Result |
| --- | --- |
| Provider timeout or server error | Retried up to three times; the message is not repeated |
| Credentials, model or request rejected | Stops with a message and **Try again** |
| Worker dies after the answer was saved | The next claim finishes the turn without calling the provider again |
| Worker loses its lease | It cannot start another provider step or tool call |
| The person presses **Stop** | Waiting turns are cancelled; a running turn stops at its next checkpoint |
| The admin's security version changes | The chat closes and its transcript is hidden |

A provider call that was in flight during a crash can be repeated and billed.
Business writes cannot repeat: they happen only through a confirmed intent.

Usage rows are owned by the admin chat itself, so admin spending never appears
in your product's per-user totals.

## Keep Content Safe

Messages render as escaped plain text with no Markdown, links or remote images.
Records shown under a reply are re-read through current grants on every page
load. The instructions tell the model to treat record values and tool results
as data, not instructions. That reduces prompt-injection risk; the grants and
the human confirmation are the actual controls.

## Check the Installation

`bin/rails rails_ai_admin:doctor` reports the assistant tables, the adapter's
`llm_context(context:)` signature and `resolve_job`. It never calls the adapter
or a provider, so it cannot prove that credentials work.

## Current Limits

The assistant has been verified with RubyLLM's real OpenAI provider and tool
loop against offline fixtures, in the engine suite and in a packaged
Devise/Pundit/PostgreSQL host with a browser check. It has not yet been verified
against a live provider. Streaming, budget limits, page or selection context,
aggregate tools, host-overridable instructions and chat retention are not
available yet.
