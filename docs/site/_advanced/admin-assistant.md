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
* How to let it propose creates, updates and deletes, and ask about a page.
* How it compares with other Rails admins' AI features.
* How turns recover after a crash, and what still needs real-provider checks.

## Understand the Boundary

The assistant answers questions about records the signed-in admin can already
open, reads their audited history, and can suggest a create, update, delete or
declared business operation. It cannot change data itself. Every suggestion,
including a create, becomes a review Surface, and only the person's own
confirmation in that review runs it: as that person, with their current grants,
a record-version check and an audit event, through the same Operation Runner as
the native pages.

Admin Chat is off by default. A conventional install loads no RubyLLM code,
creates no assistant tables and never calls a provider.

## Install

The gem does not depend on RubyLLM. Add `ruby_llm` (>= 2.2.0, < 3; boot checks
the range) to your Gemfile and run the generator:

```sh
bin/rails generate rails_ai_admin:assistant
bin/rails db:migrate
```

The migrations create three Engine-owned tables: `rails_ai_admin_assistant_chats`,
`_messages` and `_turns`. Tool calls and token usage go into RubyLLM's own
`ruby_llm_tool_calls` and `ruby_llm_usages` tables. The migrations create those,
and RubyLLM 2.2's `ruby_llm_queued_messages` and `ruby_llm_chat_files`, only when
your application has none yet, and add only the RubyLLM 2.2 columns that are
missing. Admin rows never share records with your product's conversations, even
when ids are equal.

In an app without Active Storage, RubyLLM logs once at boot that
`RailsAiAdmin::Assistant::Message` has no attachments. Admin Chat sends no
attachments, so you can ignore that line.

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
`surface: true, assistant: true`. Native Surface permission alone does not
expose an operation to the assistant.

Each actor may send 100 messages in any 24 hours by default; the next message is
refused with a plain explanation before any provider call. Continuations after a
confirmed review are not counted. Change or remove the limit deliberately:

```ruby
config.assistant_daily_message_limit = 300  # or nil for no limit
```

Assistant turns run in Active Job on the `rails_ai_admin` queue (see
`config.queue_name`). A retryable failure schedules its own delayed retry, so a
host without a scheduler still retries. Use a persistent queue and schedule
recovery for jobs lost in a crash:

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
| `describe_resource` | Readable fields, searchable fields with their match mode (`prefix`, `contains`, `exact`), filterable and sortable fields, granted list scopes, and member operations that can be proposed |
| `search_records` | Up to 20 records through the shared list query, independent of the native page size. It searches every record the actor may see unless the model passes a granted `scope`; a resource's default list tab never applies silently. Accepts `sort` and `direction`. Every result reports `applied_scope`, `applied_sort` and how many records were `omitted` because their `show` check failed. When `has_more` is true, pass `next_offset` as `offset`, including after byte truncation. At 1,000 records, `limit_reached` asks for a narrower query |
| `count_records` | The number of records matching the same query, filters and scope, capped like the index count (`capped: true` above it) |
| `get_record` | One record's readable fields |
| `record_history` | The latest 20 audited changes to one record: time, change, field labels under current grants, who and through what. Needs the `view_history?` grant; values are never returned because they are never recorded |
| `propose_change` | A review Surface for a native create, update or delete, when the resource declares it with `assistant_changes` (only with `config.surfaces`) |
| `propose_operation` | A review Surface for one declared member operation (only with `config.surfaces`) |

Field values are typed JSON: null is `null`, booleans and integers keep their
JSON types, decimals are exact strings padded to their scale, dates and times
are ISO 8601, a select is `{value, label}` (filter with the value) and a
reference is `{id, label, resource}`, with `resource: null` when the actor
cannot open the target. A registered field type is sent as its formatted text,
because its formatter may redact. Files are sent as name, type and size, rich
text as plain text, and a `references` list as `{id, label, resource}` items.
Passwords never reach a tool result. The instructions carry `PROMPT_VERSION` 3.

Results are bounded JSON (16 KB). Errors carry only a fixed code such as
`NOT_FOUND`, `INVALID_QUERY` or `CONFLICT`, never a stack trace or SQL.

## Follow a Proposal

1. The model calls `propose_operation`. The admin authorizes the operation
   against the record, runs its preflight and saves an unconfirmed intent with
   origin `assistant`. Nothing in your data changes.
2. The conversation shows the review Surface with the input and the proposed
   visible changes (before → after) from the operation's pure preflight, as the
   native confirmation page does. A retried tool call shows the same review
   rather than preparing another one.
3. The person confirms or dismisses it, and returns to the conversation either
   way. Confirming writes the change, audit and receipt in one transaction with
   the Surface's new revision, and the chat receives one continuation turn
   describing the committed result. Dismissing expires the unconfirmed intent,
   changes nothing else and tells the chat once that the user declined.
4. The assistant replies to that result in the same conversation.

A repeated confirmation, or a confirmation on the native page first, writes
nothing twice and admits no second continuation. If the chat was archived in
the meantime, the confirmation still succeeds; only the follow-up is skipped.

## Let It Propose Creates, Updates and Deletes

A resource opts in to native change proposals:

```ruby
class TicketAdmin < RailsAiAdmin::Resource
  # ...
  assistant_changes :create, :update   # add :destroy to allow delete proposals
end
```

`describe_resource` then lists each allowed change with the fields the person may
set (never passwords or files). When the model calls `propose_change`:

1. The admin checks the resource's `assistant?` grant, the declaration, the
   person's own `create`/`update`/`destroy` grant on the record and their field
   write grants, then coerces the values exactly as a form would. An unknown,
   unwritable or badly typed field is refused with the field names, and nothing
   is saved but an unconfirmed intent that records the record's version.
2. The conversation shows a review titled "Update ticket" (or Create, Delete)
   with each changed field as before → after, labelled through current read
   grants; references show their targets' labels. A delete review says it cannot
   be undone and its button reads **Delete**.
3. Confirming runs the write as the person. If the record changed after the
   proposal, the review reports a conflict instead of overwriting. The chat then
   hears the committed result, including a new record's id.

Creates wait for confirmation too: nothing the model suggests reaches your data
without a person's click.

## Ask About a Page

When admin Chat is available for a resource, its record and list pages show
**Ask the assistant about this record** (or **this list**). The question starts a
new conversation whose first message begins with a server-written line such as
`Context: I am looking at Ticket 42 ("Printer offline") in the tickets resource.`
The line is added only after the server checks the `assistant?` grant and the
record's scope and show grant again; a list adds its search text and list tab.
It is visible in the transcript, it is data for the model, and it grants nothing:
the model still reads the record with its tools.

## Streaming Replies

Replies stream: the worker asks the provider to stream and saves the text written
so far on the turn about three times a second, and the conversation refreshes
faster while a reply is being written. The streamed text belongs to the worker
that holds the turn's lease, is cleared when the finished message is saved, and
is shown only while the chat is current for the person. Set
`config.assistant_streaming = false` for a provider endpoint that cannot
stream. Like every message, it
renders as plain text: markup from a model never becomes a link or an image.

## Connect Outside Agents

[MCP Server]({% link _advanced/mcp-server.md %}) offers the same tools to agents
such as Claude Code or Cursor under personal access tokens; their proposals wait
for confirmation in the admin.

## Recover From Failures

Sending a message saves it as a queued turn and returns at once; no provider
call runs in a web request. A worker claims the oldest turn of a chat under a
lease, so later messages wait their turn. The page refreshes while a turn is
pending and offers a Refresh link without JavaScript. Activity lines come from
each tool's stored result, so a failed call reads "Tried to open a record in
Customers (not available)", never as done.

| Situation | Result |
| --- | --- |
| Provider timeout or server error | Retried up to three times with a delayed job the worker schedules itself; the chat shows "Retrying (2 of 3)". The message is not repeated. The scan only recovers a lost job |
| A request ends without an answer | Before the next message, the assistant records "I could not answer the previous message." so the model does not read two messages as one request |
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
Devise/Pundit/PostgreSQL host with a browser check. The same host has run the
full flow once each against OpenAI, Anthropic and Google models through
RubyLLM's OpenRouter provider. Native OpenAI and Anthropic APIs, provider
failures against a live service and repeated runs are not verified yet.

`search_records` matches its query as one contiguous phrase with each field's
match mode, like the index search box: a live model that searched for
`lobby printer` did not find a ticket titled `Printer offline in lobby`.
`describe_resource` now tells the model each field's mode. Some models also answer in Markdown,
which the transcript shows as literal characters.

Cost budgets beyond the message limit, selection context, proposals that change
several records at once, undo, aggregates other than counting, host-overridable
instructions and chat retention are not available yet. Streaming is saved and
polled, not pushed over WebSockets.

## How It Compares

As of November 2026, ActiveAdmin, Administrate, RailsAdmin and madmin ship no AI
assistant; teams add one with a general library such as RubyLLM. Avo 4 sells an
AI add-on with a larger toolset (bulk updates, imports and undo, besides
streaming and an MCP server, which this engine has too). What this engine does differently:

| | Rails AI Admin | Typical approach |
|---|---|---|
| Price | Part of the MIT gem | Add-on or custom code |
| Who writes | Only a person's click on a review, for every create, update, delete and operation | Often creates or "safe" actions apply at once |
| Write path | The same audited Operation Runner as the forms: intent, version check, transaction, audit, receipt | Tool code calls the model API directly |
| Concurrent edits | A stale proposal conflicts instead of overwriting | Usually last write wins |
| Exposure | Default-deny `assistant?` per resource, then the person's own index, show and field grants on every call | Resource or action policies; field-level reads vary |
| Secrets | Write-only passwords and unreadable fields never reach tool results; files are metadata only | Depends on each tool |
| Provider credentials | Built per admin Context; your global RubyLLM settings are never read or changed | Global configuration |
| Database | SQLite and PostgreSQL | Often PostgreSQL only |
| Outside agents | An MCP server under revocable personal tokens, with the same grants and reviewed writes | Separate integration or none |
| Evidence | A 23-question evaluation set replayed offline in the test suite, with prompt-injection and cross-tenant cases | Rarely published |

If you need bulk AI edits, AI imports or undo today, an add-on such as Avo's
covers more ground; if you need every AI-suggested change to be a reviewed,
audited, version-checked write under your existing policies, this engine is built
for that.
