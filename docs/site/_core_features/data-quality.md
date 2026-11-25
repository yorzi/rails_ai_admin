---
layout: default
title: "Data Quality Rules"
nav_order: 21
description: "Find duplicates or missing values in permitted records and review a correction in the admin."
---

# {{ page.title }}

On a resource list, choose **Data quality** and open a check. A duplicate check shows matching records together with the fields used for comparison. Open **Edit record** to correct a value, then run the check again. A host can also link a finding to an existing member operation that has its own preview, confirmation and receipt.

In `bin/demo`, sign in as Admin and open **Orders → Data quality → Orders missing a delivery date**. The demo includes orders with and without a delivery date.

## Register a check

Put the rule in an autoloaded host directory. Register its class name in the Rails AI Admin initializer. Rails reloads the rule with the resource registry.

```ruby
# app/rails_ai_admin/duplicate_customer_names.rb
class DuplicateCustomerNames < RailsAiAdmin::QualityRule
  key :duplicate_names
  resource :customers
  description "Customers with the same name"
  severity :warning
  remediation_change :update
  max_findings 50
  max_duration 5

  def detect(_context, relation)
    RailsAiAdmin::Quality::Checks.duplicates_by(relation, columns: [:name], normalizer: :lower_trim)
  end
end

# config/initializers/rails_ai_admin.rb
RailsAiAdmin.configure do |config|
  config.quality_rules = ["DuplicateCustomerNames"]
end
```

Grant the check in the host authorization adapter. Every preset starts with quality checks closed. A Pundit resource policy can implement `run_quality_rule?(rule)`.

```ruby
def run_quality_rule?(context:, resource:, rule:)
  context.actor.data_steward? && resource.key == :customers && rule == :duplicate_names
end
```

The engine requires index access, applies the resource’s tenant scope and soft-delete filter, then checks show access and evidence field visibility on every returned record. A finding is omitted if any of its candidate records or evidence fields is unavailable. Read access to a finding and permission to correct it are independent. Use `remediation_operation :your_member_operation` to open a host-defined operation in place of the ordinary edit form.

## Write a detector

Use the supplied relation for domain reads. `duplicates_by` groups in SQL by one or more columns, skips null keys and returns up to 20 records per group in primary-key order. The default comparison is `:exact`. For text columns, `:lower_trim` uses the database’s `LOWER(TRIM(...))` semantics. `blank_fields(relation, fields: [:name, :email])` finds records with a null value in any named column or an empty or space-only text value. Both helpers use column names as evidence field names, so those fields must be declared on the resource.

A custom detector can return an array or lazy enumerable of `RailsAiAdmin::Quality::Finding` objects. Pass a stable finding key, one to 20 canonical record IDs, a short fixed summary and up to ten scalar evidence field names. Include each field whose value the finding reveals. Use the summary for an operator-facing explanation such as “Missing settlement date.” The engine formats the actual values from the live, authorized field projection.

```ruby
RailsAiAdmin::Quality::Finding.new(id.to_s, [id], "Missing settlement date", [:settled_on])
```

The runner inspects up to `max_findings` candidates (1–100) and applies a cooperative `max_duration` of 1–30 seconds. Host Ruby runs under Active Record’s ordinary write guard, including lazy enumeration. Bound the work performed by the detector itself, use indexes appropriate to the host data and keep external effects out of detectors. A slow SQL statement can exceed the cooperative deadline before control returns to Ruby.

## Ask the assistant

With the assistant enabled, a person who has both the resource’s assistant grant and a rule grant can ask which checks are available and run one. The chat and MCP tools use the same runner as the native page. Tool output contains the check summary, permitted record IDs and bounded, formatted evidence. Corrections use the admin’s existing write workflow.
