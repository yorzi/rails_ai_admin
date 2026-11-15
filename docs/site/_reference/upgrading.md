---
layout: default
title: Upgrading
nav_order: 2
guide: false
description: Upgrade an existing host to 0.4.0 and choose its assistant limits.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

## Upgrade to 0.4.0

0.4.0 adds no migration and changes no template the generator copies. Every new
capability is opt-in, so an upgraded host behaves as before until you choose
them. Check these if you use admin Chat or the MCP server:

* **Spending limits.** Nothing is limited beyond the existing 100 messages per
  person per day. Consider `config.assistant_daily_token_limit` and
  `config.assistant_daily_cost_limit`; see
  [Limit Spending]({% link _advanced/admin-assistant.md %}#limit-spending).
  `rails_ai_admin:doctor` now reports which limits are set.
* **Retention.** Conversations are still kept until deleted. To delete quiet
  ones, set `config.assistant_retention` and schedule
  `bin/rails rails_ai_admin:assistant:prune` daily.
* **New tools.** The model now sees `aggregate_records` (it answers only for
  fields you declare `aggregatable: true`) and, when a resource declares
  `assistant_changes :bulk_update`, `propose_bulk_change`. A host test that
  asserts the exact tool list must add them. The instructions are
  `PROMPT_VERSION` 4.
* **Three single reviews per reply.** A fourth `propose_change` or
  `propose_operation` in the same reply returns `LIMIT_REACHED`. A host flow that
  expected more reviews from one message must split it, or use a bulk change.
* **Questions asked from a page over a limit.** They now open the new
  conversation with the question kept and the reason shown (429) instead of an
  access-denied page.
* **Bulk changes need `secret_key_base`**, which every Rails application has, and
  your policy's `select_records?` grant for the person.

For changes required by earlier versions, see the
[0.3.0 upgrade guide](https://github.com/yorzi/rails_ai_admin/blob/v0.3.0/docs/site/_reference/upgrading.md).
For a new installation, follow the [Quickstart]({% link _getting_started/quickstart.md %}).

Review the [Public Preview limits]({% link _getting_started/whats-new-in-0-4.md %}#public-preview-limits)
and run the host's authentication and authorization tests before deploying.
