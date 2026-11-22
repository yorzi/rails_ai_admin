---
layout: default
title: What's New in 0.5
nav_order: 6
description: The assistant learns your business terms, falls back to other models, caches its repeated prompt, totals by calendar period and can be checked on your own questions before rollout.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* How to tell the assistant what your records and terms mean.
* How fallback models and prompt caching keep it available and cheaper.
* How it totals records per day, week, month or year.
* How to check it on your own questions before staff use it.
* What the new recordings with real models show, and what they do not.
* What to do when you upgrade, and where the Public Preview still has limits.

## Tell It About Your Business

The model knows your field names, not what they mean to your team. The
assistant adapter may define `instructions(context:)`:

```ruby
class AdminAssistant
  def instructions(context:)
    "A VIP customer has at least 100 points. delivery_on is the promised date."
  end
end
```

The text follows the admin's own rules as a second system message on every turn,
introduced as notes from the operators. It is never saved and grants nothing:
every tool still applies the person's grants, and every change still waits for a
confirmed review. See
[Tell It About Your Business]({% link _advanced/admin-assistant.md %}#tell-it-about-your-business).

## Fall Back to Another Model

```ruby
config.assistant_fallback_models = %w[gpt-4.1-nano]   # up to three
```

When the assistant model is rate limited, overloaded or unreachable, RubyLLM
retries the same request on these models before the turn fails. Rejected
requests, missing credentials and content filters never fall back. Every attempt
is in the usage ledger, so spending limits include it, and the doctor lists the
fallbacks. See
[Fall Back to Another Model]({% link _advanced/admin-assistant.md %}#fall-back-to-another-model).

## Cache the Repeated Prompt

Every request in a conversation repeats the same instructions and tool
definitions, several times in one reply while the model calls tools. The
assistant now asks the provider to cache them, ending the cached part after your
operator notes. This is on by default:

```ruby
config.assistant_prompt_caching = false   # only for a compatible server that rejects unknown fields
```

In the recordings made for this release, later requests read most of the prompt
from the cache: 15,325 of 17,348 tokens in a four-request reply on
`anthropic/claude-haiku-5.5`, and 11,739 of 12,589 in a reviewed update on
`openai/gpt-6-luna`. `google/gemini-3.8-flash` reported no cache reads. The
spend line shows the tokens read from the cache; they still count toward the
token limit, and the cost reflects the provider's lower price. See
[Cache the Repeated Prompt]({% link _advanced/admin-assistant.md %}#cache-the-repeated-prompt).

## Totals per Day, Week, Month or Year

`aggregate_records` groups by calendar period. Pass a date or datetime field the
person may filter by as `group_by`, with `period` set to `day`, `week`, `month`
or `year`:

```ruby
fields do
  decimal :total, aggregatable: true
  date :delivery_on, filterable: true
end
```

"What was the order total per week of delivery?" returns periods oldest first in
the person's time zone, with empty periods counted as zero and at most the latest
25. `describe_resource` lists these fields as `group_by_period`. See
[Calculate Totals]({% link _advanced/admin-assistant.md %}#calculate-totals).

## Check It Before Rollout

The doctor proves the wiring, not the answers. Write the questions your staff will
ask in `config/rails_ai_admin/assistant_eval.yml`, with the tools you expect and,
optionally, a reference answer, then run them as one person:

```sh
bin/rails rails_ai_admin:assistant:eval ACTOR=raa:actor:User:1 TENANT=raa:tenant:Account:1
```

Each case runs through your model, that person's grants and your operator notes,
exactly as the page would. The task prints one line per case and the cost, and
exits with status 1 on a failure, so it can run against a staging database in CI.
It is built on [RubyLLM evaluations](https://rubyllm.com/evaluations/); the
assistant generator writes a starter file. See
[Check It Before Rollout]({% link _advanced/admin-assistant.md %}#check-it-before-rollout).

## Rich Text Under Turbo

The default layout loads Trix in its head whenever a resource has a `rich_text`
field. Opening an editor through a Turbo visit no longer shows the link dialog
open with Trix's styles refused by the page's style policy. Layout overrides move
to contract 5; see [Upgrading]({% link _reference/upgrading.md %}).

## Tested With Real Models

Every OpenRouter recording was made again on 2026-11-22 through RubyLLM 2.2.3,
with prompt caching on:

| Scenario | Models |
| --- | --- |
| A total and a count, with real usage feeding the budget | `openai/gpt-6-luna` |
| Active customers per month, from period groups | `openai/gpt-6-luna` |
| Operator notes that define "gold customer", answered from the cache | `anthropic/claude-haiku-5.5` |
| Another tenant's record and an invoice carrying injected instructions | `openai/gpt-6-luna` |
| One bulk review, confirmed, that updates four records | `openai/gpt-6-luna` |
| A single reviewed update, confirmed, then the follow-up answer | `openai/gpt-6-luna`, `anthropic/claude-haiku-5.5`, `google/gemini-3.8-flash` |
| The 27-question evaluation set | `openai/gpt-6-luna`: 26 pass |

The miss is `count-inactive`: the model answered "4" correctly with
`aggregate_records` instead of the expected `count_records`. The recordings also
found a usefulness gap. Asked to "list the invoice numbers of Judy Jones", the
model searched invoice numbers for her name twice instead of finding the customer
first. The isolation scenario now names that step, so the reply always reads the
invoice carrying injected instructions. Tenant isolation held in every attempt.

The recordings show how this engine handles those replies, not how a model
answers today. Fallback models and the evaluation task have tests against a
scripted provider only; native OpenAI and Anthropic APIs are still unchecked.

## Upgrading

0.5.0 adds no migration. Caching is on by default; the other features are opt-in.
Running `bin/rails generate rails_ai_admin:assistant` again adds the starter
evaluation file and leaves an existing adapter alone. A layout override needs
`<%= admin_rich_text_assets %>` in its head; the doctor reports it as
`STALE_CONTRACT` until then. See the [upgrade guide]({% link _reference/upgrading.md %}).

## Public Preview Limits

* Ruby 3.3 or newer (CI uses 4.0.10 and 3.3.14), Rails 8.1.4.1 or newer below
  8.2, and SQLite or PostgreSQL. A nightly job runs the suite against Rails main
  as an early warning; Rails 8.2 is not supported yet.
* Bulk changes and bulk actions take up to 100 records. Undo of a confirmed
  change is not available.
* Native OpenAI and Anthropic APIs, fallbacks against a live service and
  repeated live runs still need verification. A human screen-reader pass and an
  independent host trial are still open.
* Public Preview contracts may change across 0.x versions.

See [Development Status]({% link _reference/development-status.md %}) for the
full list, and [What's New in 0.4]({% link _reference/whats-new-in-0-4.md %}) for
the previous release.

## Next Steps

* [Admin Assistant]({% link _advanced/admin-assistant.md %}) - add operator notes, fallbacks and an evaluation file.
* [Template Overrides]({% link _advanced/template-overrides.md %}) - move a layout override to contract 5.
* [Upgrading]({% link _reference/upgrading.md %}) - prepare an existing 0.4 host for 0.5.
