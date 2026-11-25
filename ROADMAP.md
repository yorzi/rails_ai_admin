# Roadmap

Rails AI Admin is a Public Preview. See the [0.5.0 changelog](CHANGELOG.md#050-2026-11-22) for changes and
[COMPATIBILITY.md](COMPATIBILITY.md) for version-specific validation evidence.

## 0.2.0: simpler setup (released)

- Rails 8.1.4.1+ within the 8.1 series, Ruby 3.3+, SQLite and PostgreSQL.
  Rails 7 and 8.0 are not supported.
- Detect existing Rails authentication or Devise, with host files preserved on rerun.
- Opt-in trusted-staff policy; default installation continues to deny policy access.
- Multiple and namespaced model generation, schema-based fields and explicit registration.
- Compact record lists, identity/sign-out controls and a collapsible mobile menu.
- Packaged fresh-app setup checks alongside independent host and recovery tests.

These changes do not establish adoption or production suitability for every host.
An independent app trial and human screen-reader review remain open. A hosted
read-only demo is a future task, not part of this release's claim.

## 0.3.0: everyday list work (released)

- `contains`, `in` (any of) and `blank` filters, declared per field.
- Sorting and searching by a `belongs_to` reference, under the target's grants.
- Numbered pages for counted lists, and personal saved views.
- One-step bulk delete and collection operations from the list, including all
  matching records up to 100, still through their review pages.
- Soft delete with a Deleted records page and a separate restore grant.
- Editing children from the parent page, returning there after saving.
- A doctor summary line and a problems-only mode.

## 0.4.0: AI that earns the name (released)

- Per-person token and cost limits over any 24 hours, from RubyLLM's usage
  ledger, shown on the conversation page.
- Conversation retention with a prune task that keeps the spending record.
- Totals, averages, extremes and per-group results under field grants.
- One reviewed change across up to 100 records, applied record by record as the
  person; at most three single reviews per reply.
- Real conversations with OpenAI, Anthropic and Google models through
  OpenRouter, recorded and replayed in the test suite, and a 27-question
  evaluation set recorded the same way.
- `bin/demo --openrouter` for the demo on real models.

## 0.5.0: assistant configuration, evaluation and operational hardening (released)

- Operator notes from the adapter, read for every turn, that explain terms
  without granting anything.
- Fallback models for rate limits, overloads and outages, through RubyLLM.
- Prompt caching of the instructions and tools, with cache reads on the spend line.
- Totals per day, week, month or year in the person's time zone.
- `rails_ai_admin:assistant:eval` to check the assistant on a host's own
  questions before rollout.
- Rich text editors opened through Turbo navigation keep their styles.
- Security, PostgreSQL and index hardening: stricter Pundit `== true` and
  `assistant?` reference boundaries, signed bulk delete reviews, PostgreSQL
  `FOR UPDATE` and `timestamptz` fixes, upload/CSP/Trix/header redaction, and
  a new index migration.
- The OpenRouter recordings made again with caching on, including period groups
  and operator notes. Fallbacks and the evaluation task are tested against a
  scripted provider only.
- A nightly, non-blocking run against Rails main.

## 0.6.0: contextual and interactive admin (in development)

Unreleased; see the Unreleased section of [CHANGELOG.md](CHANGELOG.md).

- Contextual assistant shell drawer with follow/pin/remove controls backed by
  server-signed, actor/tenant/epoch-bound `PageContext` tokens over records,
  canonical `ListState` and fixed `Selection` snapshots (`E01`).
- Per-resource and per-field `description` semantic metadata under current read
  grants, bounded `OR` filter groups (`any`), and single-hop `belongs_to` and
  `has_many`/`has_one` `IN`-subquery relation filters (`relation_filters`) that
  avoid aggregate row multiplication (`E02` Phase 1).
- Read-only `RailsToolViews` surfaces (`raa_record_card`, `raa_record_table`,
  `raa_metric_card`) with live re-authorization on every render and graceful
  fallback when `config.surfaces` is off (`E03` Phase 1).
- Subset-selectable and editable bulk change reviews that atomically supersede
  prior previews into a fresh immutable selection and token (`E06` Delta 1).

## 0.7.0: operations and the approval inbox (implemented in development)

Operators can review another person’s proposal, track large bulk changes in Tasks, inspect verification receipts and preview undo when the host supports it. See the [unreleased changelog](CHANGELOG.md#unreleased) for the migrations and upgrade details.

## 0.8.0: data quality, import review and saved reports (in progress)

- **Data quality (E07).** Operators can run host checks for duplicates, missing values and unavailable references, compare records, choose a survivor and confirm a host-defined merge. Each confirmation rechecks permissions and record versions. The native UI works offline. Chat can open a live comparison, and MCP exposes the read-only checks. [Data quality guide](docs/site/_core_features/data-quality.md)
- **CSV import (E08).** Operators can map and review up to 100 rows, skip scoped duplicates and confirm one audited create per selected row. Optional AI mapping suggestions use headers and writable field definitions. Chat can reopen the latest draft in a private review card. Resumable large imports and failed-row download and retry remain planned.
- **Cross-resource queries (E02-P2).** Operators can search a related resource, include or exclude records with a matching relation, and break down an aggregate by category and calendar period. Each query uses the viewer’s current grants on both resources. [Assistant query guide](docs/site/_advanced/admin-assistant.md)
- **Saved queries and dashboards (E09).** Planned work includes saving a query, sharing it and pinning a chart to Overview. Each chart will recheck the viewer’s permissions when rendered.

## Next candidates

- **Propose-only recipes & automation (`0.9` target):** versioned manual,
  scheduled and event-driven recipes with explicit execution principals,
  isolated budgets and approval-inbox routing.
- **Everyday admin & validation (ongoing):** child forms that save with the
  parent, polymorphic references, separately controlled attachment changes,
  native OpenAI and Anthropic API checks, human screen-reader review, an
  independent host trial, more locales and additional policy adapters.

No date or version is committed for these candidates. Beta and 1.0 require broader
host validation, stable contracts and evidence beyond the local test suite.
