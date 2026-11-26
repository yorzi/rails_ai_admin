---
layout: default
title: Recipes
nav_order: 26
description: Run scheduled checks and send proposed operations to a separate human reviewer.
---

# {{ page.title }}

A recipe runs one bounded check against a registered resource. It can create a task with a live result or propose one host-defined member operation. To apply the proposal, a different operator must open Tasks, review the input and confirm it. The runner checks the target version and both the current proposer and reviewer grants.

## Install and configure

Copy the engine migrations with `bin/rails generate rails_ai_admin:install --skip` and run `bin/rails db:migrate`. The context adapter must implement `resolve_job(actor_ref:, tenant_ref:, security_version:)` using current host identity and grants. The owner and execution principal both need `assistant?` and `run_recipe?(context:, resource:, slug:)` on the resource. Grant `view_tasks?` to operators who use the inbox. A proposed member operation must declare `approval: :separate_actor`.

Run the following setup in trusted host code with resolved owner and principal contexts. Replace the example scope, operation and input with declarations from the host resource.

```ruby
RailsAiAdmin::Recipes.configure!(
  owner: operator_context, principal: service_context, slug: "overdue_orders",
  name: "Review overdue orders", resource: :orders,
  instructions: "Review the first overdue order for follow-up.",
  trigger: "schedule", cron: "30 9 * * 1-5", time_zone: "America/New_York",
  plan: { template: "order_monitor", scope: "overdue",
          operation: "request_follow_up", input: { reason: "Overdue order" } },
  overlap: "queue_one", daily_limit: 12, enabled: true
)
```

Configure the same tenant and slug again to revise or disable it. Each change advances the version. A queued run from an older version is cancelled and pending proposals from that version cannot be approved. Failed authority checks pause the recipe. Resolve fresh contexts before enabling it again.

## Trigger and recover runs

Schedule `bin/rails rails_ai_admin:recipes:scan` every minute and run an Active Job worker on the engine queue. The scan admits one due occurrence per recipe and re-enqueues waiting work. A missed spring-forward minute is skipped. Both occurrences of the same fall-back minute use one local-time key. After scheduler downtime the scan coalesces missed occurrences. The default overlap policy skips overlapping work. `queue_one` allows one waiting successor. Runs already claimed by an interrupted worker fail after ten minutes. A new occurrence can then be admitted.

For a manual recipe use **Tasks → Recipes → Run for review**. Event recipes use `trigger: "event", event: "orders.changed"` and require that event name in `config.recipe_events`. Emit a stable host event ID after commit. Pass `origin: :recipe` when forwarding events asynchronously from a recipe-derived operation. Synchronous events emitted during approval are suppressed automatically.

```ruby
RailsAiAdmin::Recipes.emit("orders.changed", tenant_ref: tenant_ref,
  dedup_key: event.id.to_s, payload: { record_id: order.id })
```

## Choose a check

| Template | Required host binding | Observation |
| --- | --- | --- |
| `duplicate_detector`, `data_hygiene`, `integrity_checker` | Registered `rule` | Number of visible findings from the quality rule |
| `order_monitor` | Optional named `scope` | Up to 25 matching records, in list order |
| `daily_business_brief` | A visible `report_id` on the same resource | Live metric or number of displayed rows |
| `failed_job_investigator` | Audit-log grant | Failed activity on this resource |
| `audit_reviewer` | Audit-log grant | Up to 1,000 audit events in the last 24 hours |

Quality and list recipes can bind an operation and its input. A run proposes at most one matching record. Read-only tasks recompute the result when opened under the viewer’s grants. The recipe library shows recent run statuses, versions and task links.

## Optional model decision

Set `consult_model: true` in a proposal plan to ask the configured assistant model whether to send that proposal to a reviewer. The request contains the instructions and the bounded observation. It has no tools. The model can suppress a review and cannot select an operation, target or input.

Configure `recipe_daily_token_limit` and `recipe_daily_cost_limit` for recipe requests in each tenant over a rolling 24 hours. Defaults are 20,000 tokens and USD 1. One model-assisted run at a time may hold the tenant’s provider slot. RubyLLM attributes usage to the recipe run separately from interactive chats. Limits are checked before a request, so the final request can cross the limit. A previous request without a known price blocks subsequent recipe requests during that window.
