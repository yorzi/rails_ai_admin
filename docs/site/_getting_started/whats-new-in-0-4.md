---
layout: default
title: What's New in 0.4
nav_order: 6
description: The assistant calculates totals, proposes one reviewed change for many records, stays within spending limits, forgets old conversations on schedule and is tested against real models.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* How the assistant answers totals, averages and per-group questions.
* How one review can change many records.
* How to cap what each person spends on the assistant.
* How conversations are deleted after a retention period.
* What the recorded real-provider tests prove, and what they do not.
* What to do when you upgrade, and where the Public Preview still has limits.

## Totals and Averages

The new `aggregate_records` tool counts, sums, averages and finds the minimum or
maximum of a field, optionally per group, over the same search, filters and list
scope as a search. Fields opt in:

```ruby
fields do
  decimal :total, aggregatable: true
  select :state, choices: STATES, filterable: [ :in ]
end
```

"What is the total of all draft orders?" becomes one exact answer instead of a
model adding up pages of results. The field needs the person's read grant, and a
group field needs their filter grant. See
[Calculate Totals]({% link _advanced/admin-assistant.md %}#calculate-totals).

## One Review for Many Records

A resource that declares `assistant_changes :update, :bulk_update` lets the
assistant propose the same values for up to 100 records as one review:

```ruby
class CustomerAdmin < RailsAiAdmin::Resource
  # ...
  assistant_changes :update, :bulk_update
end
```

The conversation shows one card. Its review page lists every record's before →
after and the records that will be skipped, and writes nothing. Confirming
updates each record as the person through the native update, with its own
version check and audit event; a record changed since the proposal makes the
review out of date instead of being overwritten. The person needs the
`select_records?` grant, as for the list's own bulk actions. See
[Change Many Records in One Review]({% link _advanced/admin-assistant.md %}#change-many-records-in-one-review).

One reply can also prepare at most three single-record reviews, so a request for
"every customer" no longer becomes a review per record.

## Spending Limits

```ruby
config.assistant_daily_token_limit = 500_000
config.assistant_daily_cost_limit = 1.00  # US dollars
```

Each person's use in any 24 hours comes from RubyLLM's usage ledger, every token
bucket together and the cost the provider reported. Over a limit, a new message
is refused with its text kept, and a running turn stops before its next provider
request. The conversation page shows the use so far. See
[Limit Spending]({% link _advanced/admin-assistant.md %}#limit-spending).

## Conversation Retention

```ruby
config.assistant_retention = 90.days
```

Schedule `bin/rails rails_ai_admin:assistant:prune` daily to delete
conversations with no message for that long. Usage rows stay as the spending
record; conversations with an active turn or spending inside the current 24 hours
stay too. `rails_ai_admin:doctor` reports the limits and retention in effect.

## Tested With Real Models

The engine suite now replays conversations recorded with real models through
RubyLLM's OpenRouter provider on 2026-11-15:

| Scenario | Models |
| --- | --- |
| A total and a count, with real token and cost usage feeding the budget | `openai/gpt-6-luna` |
| Another tenant's record and an invoice carrying injected instructions | `openai/gpt-6-luna` |
| One bulk review, confirmed, that updates four records | `openai/gpt-6-luna` |
| A single reviewed update, confirmed, then the follow-up answer | `openai/gpt-6-luna`, `anthropic/claude-haiku-5.5`, `google/gemini-3.8-flash` |
| The 27-question evaluation set | `openai/gpt-6-luna`, all 27 passing |

The recordings hold the HTTP traffic without keys or headers. On every replay
the tools, grants, usage accounting and review pages run for real; only the
models' replies come from the recording, so a change to a tool's result or
permission still fails the suite. The first real run found a model queuing a
review for every customer when asked to change all of them, which led to bulk
reviews and the three-review cap.

The recordings show how this engine handles those replies. They do not show how a
model answers today; live checks and native OpenAI and Anthropic APIs are still
open.

## Try It in the Demo

`bin/demo --assistant` covers totals ("sum orders total by state") and bulk
reviews ("set customers points to 50 for Bulk") with the offline fake provider.
`bin/demo --openrouter` runs the same demo against real models, reading
`OPENROUTER_API_KEY` from the environment, under a US$0.25 daily limit. See
[Run the Demo]({% link _getting_started/demo.md %}).

## Upgrading

0.4.0 adds no migration. The new behavior is opt-in: `aggregatable: true`,
`assistant_changes :bulk_update`, the two spending limits and the retention
period. For the 0.4.1 fixes and the required migration, see the
[upgrade guide]({% link _reference/upgrading.md %}).

## Public Preview Limits

* Ruby 3.3 or newer, Rails 8.1.4.1 or newer below 8.2, and SQLite or PostgreSQL.
* Bulk changes and bulk actions take up to 100 records. Undo of a confirmed
  change, grouping by date periods and host-supplied instructions are open.
* A cost limit counts a request whose cost is unknown as zero; set a token limit
  too when your model has no known pricing.
* Native OpenAI and Anthropic APIs and repeated live runs still need
  verification. English ships with the engine; a human screen-reader pass is
  still open.
* Public Preview contracts may change across 0.x versions.

See [Development Status]({% link _reference/development-status.md %}) for the
full list, and [What's New in 0.3]({% link _reference/whats-new-in-0-3.md %})
for the list work of the previous release.

## Next Steps

* [Admin Assistant]({% link _advanced/admin-assistant.md %}) - turn on totals, bulk changes and limits.
* [MCP Server]({% link _advanced/mcp-server.md %}) - the same tools for outside agents.
* [Upgrading]({% link _reference/upgrading.md %}) - prepare an existing 0.3 host for 0.4.
