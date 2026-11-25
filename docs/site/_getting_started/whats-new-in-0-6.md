---
layout: default
title: What's New in 0.6
nav_order: 8
description: The assistant opens beside any admin page and knows which record, list or selection you are looking at, filters through related records, answers with live record and total cards, and lets you narrow or edit a bulk change before you confirm it.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

0.6.0 is in development; this page describes the `main` branch.
{: .note }

After reading this guide, you will know:

* How to ask about the page you are on from the assistant drawer.
* How to describe resources and fields so the assistant understands them.
* How the assistant filters through related records and combines conditions with OR.
* What the record, table and total cards show.
* How to narrow or edit a bulk change before confirming it.
* What the recordings with real models show, and what is still unverified.
* What to do when you upgrade.

## Ask About the Page You Are On

Every admin page has an **Assistant** button in the header. It opens the
assistant in a side drawer, so you can ask without leaving the page. On a record,
list or selection page the drawer shows the page as a chip:

* **Following page**: the chip changes as you move between pages.
* **Pin context**: keeps the chip while you navigate; **×** removes it.
* The conversation stays open in the drawer as you move around, and **Open full
  conversation** shows it on the assistant page.

On a list, tick records and choose **Ask assistant** to ask about exactly those
records, for example "Compare these customers".

The chip is an encrypted token bound to the person, tenant and
`security_version`, valid for one hour. Every message resolves it again under
the current grants and writes a `Context:` line the model can read, such as
`Context: I am looking at Customer 42 ("Heidi Klum") in the customers resource.`
A filter the person may no longer use is left out; an altered, foreign or
revoked token is refused. When the token or its selection has expired, the
message is not sent, its text stays in the message box, and the drawer removes
the chip. See
[Ask About a Page]({% link _advanced/admin-assistant.md %}#ask-about-a-page).

## Describe Your Resources

```ruby
class CustomerAdmin < RailsAiAdmin::Resource
  description "People and companies who buy from us. Archived customers are kept for invoices."

  fields do
    integer :points, description: "Loyalty points; 20 or more is a gold customer"
  end
end
```

`list_resources` and `describe_resource` pass these descriptions to the model,
a field's only when the person may read that field. They are plain text of up
to 500 characters for a resource and 300 for a field, and they grant nothing.

## Filter Through Related Records

`search_records`, `count_records` and `aggregate_records` take two new optional
arguments:

* `any`: up to five groups of filters; the conditions inside a group must all
  match, and a record matches when any group does. "Customers who are inactive
  or have more than 30 points" is one count.
* `relation_filters`: filters on a related resource, through a declared
  `belongs_to` field or a `has_many`/`has_one` panel, for example invoices whose
  customer has at least 20 points. Up to three relations, one hop each.

A relation filter uses the related resource's own scope, soft delete,
`assistant?` grant and filter grants, and counts and totals never count a record
twice. `describe_resource` lists the relations the person may filter through as
`filter_relations`. A relation filter uses filter fields only, so a name that is
searchable but not filterable still takes two steps: find the customer, then
filter the invoices by that customer.

## Live Record and Total Cards

With `config.surfaces` on, answers show read-only cards next to the text:

| Tool | Card |
| --- | --- |
| `get_record` | The record's readable fields and a link to its page |
| `search_records` | A table of the records found, with links |
| `aggregate_records` | The total, with its breakdown, list tab and search |

Each card reads the data again under the person's current grants whenever the
conversation is shown, so it never displays values they can no longer see.
Without `config.surfaces`, the conversation lists links to the records found, as in 0.5.

## Narrow or Edit a Bulk Change

The review page of a bulk change now lets you untick records and edit the
proposed values under **Adjust records or values before confirming**. **Update
preview** closes the old review and opens a new one for the records and values
you chose; it writes no records. Confirming applies only the review as shown:
if you untick a record or change a value and press **Update N records** without
updating the preview, nothing is updated and the page asks you to update the
preview first.

## Tested With Real Models

New OpenRouter recordings, made on 2026-11-25 through RubyLLM 2.2.3 with the 0.5
instructions unchanged, replay in the test suite:

| Scenario | Models | Result |
| --- | --- | --- |
| A record page as context: "How many points does this customer have, and which invoices belong to her?" | `openai/gpt-6-luna`, `anthropic/claude-haiku-5.5`, `google/gemini-3.8-flash` | Each read the record named by the context and listed only her invoice |
| "Which invoices belong to customers with at least 20 points?" | All three | Each used one `relation_filters` search |
| A selection as context: "Compare the points of these customers." | `openai/gpt-6-luna` | Compared exactly the three selected customers |
| "How many customers are inactive or have more than 30 points?" | `openai/gpt-6-luna` | One count with `any` |
| "List the invoice numbers of Judy Jones." | `openai/gpt-6-luna` | Found the customer, then her invoice (missed in 0.5) |
| A bulk change narrowed and edited before confirming | `openai/gpt-6-luna` | The conversation heard "3 of 3 records were updated." |
| The primary model down (a simulated 503), Claude as fallback | `anthropic/claude-haiku-5.5` | The fallback answered every request |
| The evaluation set, now 30 questions | `openai/gpt-6-luna` | 29 pass; `count-inactive` stays a recorded miss |

The recordings also found a defect, fixed before this page: a total or table
card for a search over a named list tab could not be rendered.

Recordings show how this engine handles those replies, not how a model answers
today. Native OpenAI and Anthropic APIs, a real provider outage and repeated
live runs are still unverified. An automated check of the drawer and the bulk
review found no accessibility issues, and keyboard focus moves into the drawer
and back to the **Assistant** button; a human screen-reader pass is still open.

## Upgrading

0.6.0 needs no migration. A layout override should add the drawer, which is
layout contract 6; until then the doctor reports it as `STALE_CONTRACT` and the
pages work without the drawer. The assistant can now filter through related
records, so check the filter grants of resources reached through a reference or
panel. See the [upgrade guide]({% link _reference/upgrading.md %}).

## Next Steps

* [Admin Assistant]({% link _advanced/admin-assistant.md %}) - the drawer, descriptions, relation filters and bulk reviews in detail.
* [Template Overrides]({% link _advanced/template-overrides.md %}) - move a layout override to contract 6.
* [What's New in 0.5]({% link _reference/whats-new-in-0-5.md %}) - the previous release.
