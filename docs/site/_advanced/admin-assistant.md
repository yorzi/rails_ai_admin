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
* How to let it propose creates, updates and deletes, one change for many
  records, and ask about a page.
* How it calculates totals, and how to limit its spending and keep
  conversations only as long as you need.
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
[Review Surfaces]({% link _advanced/review-surfaces.md %}) and at least one member operation with
`surface: true, assistant: true`. Native Surface permission alone does not
expose an operation to the assistant.

Each actor may send 100 messages in any 24 hours by default; the next message is
refused with a plain explanation before any provider call. Continuations after a
confirmed review are not counted. Change or remove the limit deliberately:

```ruby
config.assistant_daily_message_limit = 300  # or nil for no limit
```

## Tell It About Your Business

The model knows your field names, not what they mean to your team. Add an
optional `instructions(context:)` method to the adapter to explain terms,
conventions and where things live:

```ruby
class AdminAssistant
  def llm_context(context:) = ...

  def instructions(context:)
    <<~TEXT
      A VIP customer has at least 100 points.
      Orders ship from the Berlin warehouse; delivery_on is the promised date.
    TEXT
  end
end
```

The admin calls it for every turn, so the text can depend on the person or the
tenant and changes apply to the next message of an open conversation. It is
sent as a second system message after the admin's own rules, introduced as notes
from the operators that do not change those rules. Return `nil` or blank text to
add nothing. Text must be at most 4,000 characters without control characters
other than tabs and line breaks; anything else fails the turn with a
configuration error. The notes are never saved in the conversation.

Instructions explain; they never grant. Every tool still applies the person's
grants, and every change still waits for a confirmed review, so text such as
"you may delete orders" has no effect on what the assistant can do.

## Fall Back to Another Model

When the model is rate limited, overloaded or unreachable, RubyLLM can retry the
same request on other models before the turn fails:

```ruby
config.assistant_fallback_models = %w[gpt-4.1-nano]   # up to three
```

A fallback answers only the request that failed and the rest of that reply's
tool rounds; the next message starts on `assistant_model` again. Rejected
requests, missing credentials and content filters never fall back. With
`assistant_provider` set, each fallback must exist on that provider in RubyLLM's
model registry; one that does not is skipped with a log line. Otherwise RubyLLM
prefers the providers your context configures. Every attempt is recorded in the
usage ledger, so spending limits include them. When every model fails, the turn
is retried later as described in [Recover From Failures](#recover-from-failures).
`rails_ai_admin:doctor` lists the fallbacks.

## Cache the Repeated Prompt

Every request in a conversation repeats the same instructions and tool
definitions, often several times in one reply while the model calls tools. The
assistant asks the provider to cache them, ending the cached part after your
operator notes:

```ruby
config.assistant_prompt_caching = true   # the default; false sends no cache hints
```

Anthropic models, directly or through OpenRouter, then bill the repeated part at
their cache-read price after the first request. OpenAI caches long prompts on
its own and receives an explicit breakpoint. The conversation's spend line shows
how many tokens were read from the cache; they still count toward
`assistant_daily_token_limit`, while the cost reflects the provider's lower
price. Set it to `false` if you point the `openai` provider at a compatible
server that rejects fields it does not know.

## Limit Spending

A message can cost several provider requests. Two optional limits cap what each
person spends in any 24 hours, per tenant, using RubyLLM's usage ledger
(`ruby_llm_usages`): every provider attempt of that person's admin
conversations, including retries and failed requests.

```ruby
config.assistant_daily_token_limit = 500_000  # every token bucket together
config.assistant_daily_cost_limit = 1.00      # US dollars
```

Both are unset by default. When a limit is reached:

* A new message is refused before any provider call, with its text kept in the
  box and the reason shown.
* A running turn stops before its next provider request and reports that the
  spending limit was reached. Tools the model already asked for still run, so
  the request that crosses a limit finishes; a turn can therefore end a little
  above it.
* A continuation after a confirmed review is still admitted, because the
  confirmation must never fail, but it stops the same way before calling the
  provider.

The token limit counts input, output, cache-read, cache-write and thinking
tokens. That matters: OpenRouter reports most of a repeated prompt as cached
tokens, so counting plain input tokens would see a small fraction of the use.
The cost limit uses the cost the provider reported, or RubyLLM's model pricing.
A request whose cost neither knows is counted as zero, and the conversation page
says how many such requests there were; set a token limit as well when your
model has no known pricing.

The conversation page shows the use so far whenever a limit is set, for
example "Assistant use in the last 24 hours: 1,500 of 500,000 tokens ·
US$0.0123 of US$1.00."

## Keep Conversations Only As Long As Needed

Conversations are kept until someone deletes them unless you set a retention
period, then schedule the prune task daily:

```ruby
config.assistant_retention = 90.days  # from 1 day to 10 years
```

```sh
bin/rails rails_ai_admin:assistant:prune
```

It deletes conversations that had no new message for that long, with their
turns, messages, tool calls, queued messages and chat files. It keeps:

* RubyLLM's usage rows, without the chat and message ids, as the record of what
  was spent;
* conversations with a queued or running turn, and conversations with usage
  inside the 24-hour budget window, so today's spending stays counted;
* review Surfaces, which belong to rails_tool_views: use its own
  `RailsToolViews.purge_closed` lifecycle for them.

`bin/rails rails_ai_admin:doctor` reports the message, token and cost limits
and the retention in effect.

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

Reference labels, searches through a reference and sorts by a reference
also require `assistant?` on the target resource. The target's own field
and record grants still apply.

## Know the Tools

| Tool | Returns |
| --- | --- |
| `list_resources` | Exposed resource keys and labels |
| `describe_resource` | Readable fields, searchable fields with their match mode (`prefix`, `contains`, `exact`), filterable and sortable fields, granted list scopes, and member operations that can be proposed |
| `search_records` | Up to 20 records through the shared list query, independent of the native page size. It searches every record the actor may see unless the model passes a granted `scope`; a resource's default list tab never applies silently. Accepts `sort` and `direction`. Every result reports `applied_scope`, `applied_sort` and how many records were `omitted` because their `show` check failed. When `has_more` is true, pass `next_offset` as `offset`, including after byte truncation. At 1,000 records, `limit_reached` asks for a narrower query |
| `count_records` | The number of records matching the same query, filters and scope, capped like the index count (`capped: true` above it) |
| `aggregate_records` | A count, sum, average, minimum or maximum over the same query, filters and scope, optionally grouped by a category field (see [Calculate Totals](#calculate-totals)) |
| `get_record` | One record's readable fields |
| `record_history` | The latest 20 audited changes to one record: time, change, field labels under current grants, who and through what. Needs the `view_history?` grant; values are never returned because they are never recorded |
| `propose_change` | A review Surface for a native create, update or delete, when the resource declares it with `assistant_changes` (only with `config.surfaces`) |
| `propose_operation` | A review Surface for one declared member operation (only with `config.surfaces`) |
| `propose_bulk_change` | One review that sets the same values on up to 100 records, when a resource declares `bulk_update` (see [Change Many Records in One Review](#change-many-records-in-one-review)) |

Field values are typed JSON: null is `null`, booleans and integers keep their
JSON types, decimals are exact strings padded to their scale, dates and times
are ISO 8601, a select is `{value, label}` (filter with the value) and a
reference is `{id, label, resource}`, with `resource: null` when the actor
cannot open the target. A registered field type is sent as its formatted text,
because its formatter may redact. Files are sent as name, type and size, rich
text as plain text, and a `references` list as `{id, label, resource}` items.
Passwords never reach a tool result. The instructions carry `PROMPT_VERSION` 4.

Results are bounded JSON (16 KB). Errors carry only a fixed code such as
`NOT_FOUND`, `INVALID_QUERY`, `CONFLICT`, `TOO_MANY` or `LIMIT_REACHED`, never a
stack trace or SQL.

## Calculate Totals

Fields opt in to aggregates:

```ruby
fields do
  integer :points, aggregatable: true
  decimal :total, aggregatable: true
  date :delivery_on, aggregatable: true   # minimum and maximum only
  select :state, choices: STATES, filterable: [ :in ]
end
```

`aggregate_records` then answers questions such as "What is the total of all
draft orders?" or "How many points do active and inactive customers hold?":

* `sum` and `average` take integer and decimal fields; `minimum` and `maximum`
  also take date and datetime fields; `count` takes none. Computed fields and
  registered field types cannot be aggregatable, because a registered type's
  formatter may deliberately redact what a raw sum would reveal.
* The field still needs the person's read grant. Declare `aggregatable` only on
  fields whose read grant does not depend on the record, since an aggregate
  reads the resource-level grant.
* `group_by` takes a boolean, enum, select or `belongs_to` field the person may
  filter by: filtering by each value would show the same counts. At most 25
  groups are returned, largest first, with `groups_truncated` when there are
  more. A reference group is labelled through the target's own grants.
* With `period` (`day`, `week`, `month` or `year`), `group_by` takes a date or
  datetime field the person may filter by instead, answering "What was the total
  per week of delivery?". Groups are calendar periods, oldest first, from the
  earliest to the latest dated record, and periods without records count zero.
  Each group is the period's first day; weeks start on Monday. Datetimes are
  split at midnight in the person's time zone, which the result names. At most
  the latest 25 periods are returned, with `groups_truncated` when earlier ones
  are left out; filter the field by date to choose another range. Records
  without a date form a last group with an empty key.
* For a breakdown such as “average order total by status and delivery month,” use a categorical `group_by`, a granted date or datetime `period_field`, and `period: "month"`. The tool returns occupied cells from the latest 25 periods, newest first, with a maximum of 25 cells including undated groups. Each cell contains its category, period start, count and requested measure. The overall total covers every matching record.
* It covers the same records as `count_records`: the policy relation, the
  optional search, filters and granted scope. It runs over the relation's
  primary keys, so a join in a policy scope cannot count a record twice.
* Decimal results are exact strings rounded to the field's scale; an average
  has two more places. `describe_resource` lists the aggregatable fields with
  their functions, the `group_by` fields and the `group_by_period` fields.

## Change Many Records in One Review

A request such as "set the points of every inactive customer to 5" should be one
review, not twelve. A resource opts in on top of single updates:

```ruby
assistant_changes :update, :bulk_update
```

The person also needs your policy's `select_records?` grant, as for the list's
own bulk actions. `describe_resource` then lists `bulk_update` with the writable
fields, `max_ids: 100` and `max_records` (`config.async_bulk_limit`, 1,000 by
default). When the model calls `propose_bulk_change` with the values and either
up to 100 record ids or the same query, filters, `any`, `relation_filters` and
scope as `search_records`:

1. The admin captures a fixed selection of the matching records (more than
   `max_records` is refused with `TOO_MANY`), checks each one with the native
   update's pure preview (scope, update grant, version, every value) and writes
   nothing else. Above 100 records only the first 25 are previewed; the rest
   get the grant, version and value checks.
2. The conversation shows one card, "A change to 4 records in Customers", that
   opens the review page. MCP clients receive a `review_url` instead.
3. The review page writes nothing. It lists every record with each field's
   before → after under the person's current read grants, and the records that
   will be skipped, with the reason.
4. To change the plan, untick records or edit the proposed values under
   **Adjust records or values before confirming**, then choose **Update
   preview**. That closes the old review and opens a new one for the chosen
   records and values; it writes no records. Confirming a review whose rows or
   values were changed on the page without **Update preview** updates nothing
   and asks you to update the preview first.
5. Choose **Update N records** or **Dismiss**. The first accepted decision
   closes the review. If a selected record changed after the proposal, or
   the set of writable records changed since you opened the page, open a
   fresh review before confirming.
6. Confirmation uses the native update operation for each record. Each update
   has its own transaction, version check and audit event with origin
   `assistant`. The result and the conversation include skipped or failed
   records. If execution is interrupted, completed updates stay committed.
   Start a new review for the remaining records.
7. Above 100 records, confirming queues one background
   [collection job]({% link _core_features/collection-operations.md %}#run-more-than-100-records)
   instead and opens its page. Workers update each record as above. With
   `config.surfaces` on, the conversation shows the job's progress under the
   review card. If the job cannot be queued, the review stays open so you can
   try again or dismiss it.

The proposed values travel to the review page in a token encrypted with your
application's `secret_key_base` that expires with the selection
(`config.intent_ttl`). They never appear in a URL or a log as text, and the
token grants nothing: another person's, an altered or an expired token is
`NOT_FOUND`.

One reply can also prepare at most three single-record reviews. Further
`propose_change` or `propose_operation` calls in the same reply return
`LIMIT_REACHED`, so a model cannot queue a review for every record.

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
record's scope and show grant again; a list adds its search text, list tab,
granted filters and sort. It is visible in the transcript, it is data for the
model, and it grants nothing: the model still reads the record with its tools.

On a list, tick records and choose **Ask assistant** to ask about a fixed
selection. The context line then names the selected record ids (up to 20, and
how many more).

### The Assistant Drawer

Every admin page also has an **Assistant** button in the header that opens the
assistant in a side drawer, so you can ask without leaving the page. On a
record, list or selection page the drawer shows the page as a removable chip:

- **Following page** means the chip changes as you move between pages.
- **Pin context** keeps the current chip while you navigate. **×** removes it.
- The conversation stays open in the drawer as you navigate, and **Open full
  conversation** shows it on the assistant page.

The chip carries an encrypted page context token bound to the person, tenant and
`security_version`, valid for one hour. Each message resolves it again under
the current grants: a filter you may no longer use is left out, and an altered,
foreign or revoked token is refused. When the token or its selection has
expired, the message is not sent, the text stays in the message box, and the
drawer removes the chip; send again to ask without it, or reload the page.

A layout override must render the drawer to offer it: the layout contract is
revision 6 (see [Template Overrides]({% link _advanced/template-overrides.md %})).

## Use the Conversation

Open **Assistant** and choose **New conversation**. The message box stays below
the scrollable conversation. Press Enter to send or Shift+Enter for a new line.
While a reply arrives, the message area follows it if you are at the bottom.
When reading older messages, use **Jump to latest** to catch up.

Tool activity, links to records you can access and review cards appear alongside
messages. Use **Stop** while a turn is active, or **Try again** when a failed turn
can be retried.

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
| Provider timeout or server error | Fallback models, when configured, are tried first within the same request. Then retried up to three times with a delayed job the worker schedules itself; the chat shows "Retrying (2 of 3)". The message is not repeated. The scan only recovers a lost job |
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

## Check It Before Rollout

The doctor proves the wiring, not the answers. Before giving the assistant to
staff, ask it the questions they will ask, as one of them. The assistant
generator writes `config/rails_ai_admin/assistant_eval.yml` with two examples;
replace them with your own:

```yaml
cases:
  - name: vip-count
    inputs: How many VIP customers do we have?
    expected_output: There are 4 VIP customers.
    metadata:
      tools: [count_records]
      answer_includes: ["4"]
  - name: refund-is-a-review
    inputs: Refund order ORD-0042.
    expected_output: It prepared a refund for review and did not refund the order itself.
    metadata:
      tools: [propose_operation]
```

Run it as a person and tenant your context adapter's `resolve_job` accepts:

```sh
bin/rails rails_ai_admin:assistant:eval ACTOR=raa:actor:User:1 TENANT=raa:tenant:Account:1
```

Each case opens a new conversation for that person and runs the question
through your model, their grants and your operator notes, exactly as the page
would. `tools`, `tools_absent` and `answer_includes` are checked in Ruby. When
every case has an `expected_output`, a model also judges whether the answer
means the same, using your adapter's provider context and `assistant_model`;
set `GRADER=<model>` to use another model or `GRADER=none` to run only the
checks. Give every case an `expected_output` or none.

The task prints one line per case and the total cost, writes the full report
with `REPORT=tmp/assistant_eval.json`, and exits with status 1 when a case fails,
so it can run in CI against a staging database. `ONLY=vip-count` runs selected
cases and `FILE=` reads another file. Reviews the model proposes are never
confirmed, so no record changes, but every case is a real provider request and
counts toward that person's limits. The conversations are archived afterwards.
From Ruby, `RailsAiAdmin::Assistant::Evaluation.for(context, dataset:)` returns
a [RubyLLM evaluation](https://rubyllm.com/evaluations/) class whose `run`
returns the report.

## Check the Installation

`bin/rails rails_ai_admin:doctor` reports the assistant tables, the adapter's
`llm_context(context:)` signature and `resolve_job`. It never calls the adapter
or a provider, so it cannot prove that credentials work.

## Current Limits

The engine suite replays real conversations recorded on 2026-11-22 through
RubyLLM 2.2.3's OpenRouter provider with prompt caching on: totals with real
usage and cost feeding the budget, active customers per month from period
groups, operator notes that define a term, another tenant's record and injected
instructions staying out, one bulk review, and a reviewed update with
`openai/gpt-6-luna`, `anthropic/claude-haiku-5.5` and `google/gemini-3.8-flash`.
Every OpenAI and Anthropic recording reads part of its prompt from the cache;
Gemini reports no cache reads. The recorded evaluation run of `openai/gpt-6-luna`
passes 29 of 30 questions; `count-inactive` answered correctly with
`aggregate_records` instead of the expected `count_records`.

Recordings made on 2026-11-25 cover the 0.6 features. With the drawer's page
context of a record, `openai/gpt-6-luna`, `anthropic/claude-haiku-5.5` and
`google/gemini-3.8-flash` each read that record by id and found its invoices
without the question naming the customer. All three answered "Which invoices
belong to customers with at least 20 points?" with one `relation_filters`
search. With a fixed selection as context, GPT-6 Luna compared exactly the
selected customers. It counted "inactive or more than 30 points" with one `any`
filter, and found the invoices of a customer it was given by name with a
customer search followed by an invoice filter. In a bulk change it proposed for
four records, the person unticked one and edited the value, and the conversation
heard "3 of 3 records were updated". On every replay
the admin's tools, grants, usage accounting and review flows run for real; only
the models' replies come from the recording, so a replay shows that this
engine still handles those replies correctly, not that a model answers the same
way today. Native OpenAI and Anthropic APIs, provider failures against a live
service and repeated live runs are not verified yet.

`search_records` matches its query as one contiguous phrase with each field's
match mode, like the index search box: a live model that searched for
`lobby printer` did not find a ticket titled `Printer offline in lobby`.
`describe_resource` now tells the model each field's mode. Some models also answer in Markdown,
which the transcript shows as literal characters.

A request that names a customer but asks for another resource's records can
miss: asked to "list the invoice numbers of Judy Jones", `openai/gpt-6-luna`
searched invoice numbers for her name twice instead of finding the customer
first. Recorded again on 2026-11-25 with 0.6 (the `invoices-of-named-customer`
question), it searched the customer first and then filtered her invoices.
The current tools can express that lookup in one call with `relation_filters: { customer: { _query: "Judy Jones" } }`. The related resource applies its granted search fields and match modes. To find customers with no visible invoices, use `{ invoices: { _exists: false } }`. To exclude customers who have a matching invoice, use `{ invoices: { _none: { state: { eq: "paid" } } } }` when invoice state is filterable. A missing or inaccessible customer counts as an absent relation. The 0.6 recording predates these operators.

A recording also covers fallback models: with the primary model's requests
answered by a simulated 503, `anthropic/claude-haiku-5.5` configured as the
fallback answered every request through OpenRouter. RubyLLM tries the primary
model again for each request of a reply and records each failed attempt as a
usage row with no tokens. A real provider outage has not been observed. The
evaluation task has tests against a scripted provider only. Recorded replays render the read-only
record card, record table and metric card. Undo of a confirmed change
and bulk changes over more than 100 records are not available yet. Streaming is saved and polled, not pushed over WebSockets.

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
| Evidence | Real OpenRouter conversations with OpenAI, Anthropic and Google models, recorded and replayed in the test suite, and a 27-question evaluation set with prompt-injection and cross-tenant cases | Rarely published |

If you need AI imports or undo today, an add-on such as Avo's covers more
ground; if you need every AI-suggested change, including one across many
records, to be a reviewed, audited, version-checked write under your existing
policies, this engine is built for that.
