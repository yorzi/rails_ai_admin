---
layout: default
title: Try the Demo
nav_order: 5
description: Run a seeded local admin with every feature turned on, including AI chat and MCP, from a checkout of this repository.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* How to start the demo and sign in.
* Where to find each feature in it, including AI chat and MCP.
* How the demo's grants map to your own policy.

## Start It

From a checkout, after `bundle install`:

```sh
bin/demo --assistant
```

This shows everything. The script copies the packaged session/SQLite host to
`tmp/demo`, points it at this checkout, installs Active Storage and Action Text,
migrates and seeds a fresh database, and serves it on `127.0.0.1:3917` only.
`--assistant` adds admin Chat, review Surfaces and the MCP endpoint, backed by
an offline fake model on port 3918: no API key and no network.

Other options:

| Command | Shows |
|---|---|
| `bin/demo` | Everything except AI chat and MCP |
| `bin/demo --plain` | Only the packaged customers and orders |
| `bin/demo --port 4000` | The same on another port (the fake model uses the next one) |
| `bin/demo --setup-only` | Prepares `tmp/demo` without serving it |

Every run starts from scratch, so changes you make are reset next time. Press
Ctrl-C to stop the server.

## Sign In

Open `http://127.0.0.1:3917/login`. The demo's sign-in page lists its accounts
with a **Sign in as …** button each; the form below them is filled in with the
admin account already. Every account's password is `demo-password`.

| Account | Sees |
|---|---|
| `admin@example.test` | Everything in Tenant A, with writes, imports, exports, history, the audit log, AI chat and MCP access |
| `viewer@example.test` | Tenant A read-only: lists, records and search; no passwords or write pages |
| `other@example.test` | Tenant B, which has almost no data: tenant scoping at work |

## A Tour

* **Overview**: resource cards with counts, then metrics and 30-day trend charts
  for orders and articles. See [Dashboard and Search]({% link _core_features/dashboard.md %}).
* **Search everything**: the header box searches customers, articles, tags and
  orders at once; try `upgrading`.
* **Articles**: every field type on one model without `lock_version`: email, URL,
  time of day, a cover image, a photo gallery, rich text, JSON settings, tags, and
  a write-only password. Open an article, then **Edit**. See
  [Resources and Fields]({% link _core_features/resources-and-fields.md %}),
  [File Uploads]({% link _core_features/file-uploads.md %}) and
  [Associations]({% link _core_features/associations.md %}).
* **History and Audit log**: save a change, then open the article's **History**,
  or **Audit log** in the menu for every change and export. See
  [Record History]({% link _core_features/record-history.md %}).
* **CSV**: on the Articles list, **Export CSV** downloads the current list;
  **Import CSV** checks and imports `tmp/demo/articles-import.csv`, which has one
  row that fails on purpose. See [CSV Export and Import]({% link _core_features/csv-export.md %}).
* **Bulk delete**: tick a few articles, **Capture selection**, then **Delete the
  selected records**.
* **Orders**: list tabs, typed filters, a reference picker for customers and a
  custom review operation. Customers show their orders in a panel with an **Add
  order** link.
* **Conflicts**: open the same record's edit form in two tabs and save both; the
  second save reports that the record changed.

## AI Chat and MCP

With `--assistant`, the fake model answers a few fixed phrases instead of free
questions, so you can see every path without a provider:

| Type this | What happens |
|---|---|
| `set articles 1 title to Hello` | A review shows the title before → after; only **Confirm and execute** saves it |
| `create articles with title Draft` | A create review; nothing is created until you confirm |
| `delete articles 2` | A delete review with a **Delete** button |
| `history of articles 1` | The article's audited changes |
| `search articles for upgrading` | Matching articles, linked under the reply |
| `award 5 points to 1` | A review for the customers' custom operation |

Start from **Assistant** in the menu, or from an article page with **Ask the
assistant about this record**, which opens the chat with a `Context:` line naming
the page. Replies stream in a few characters at a time.

**MCP access** in the menu issues a personal access token and shows the exact
`claude mcp add` command for `http://127.0.0.1:3917/staff/mcp`. An agent
connected with it can search and read through the admin's grants, and each change
it proposes returns a `review_url` that you open and confirm in the browser. See
[Admin Assistant]({% link _advanced/admin-assistant.md %}) and
[MCP Server]({% link _advanced/mcp-server.md %}).

## Where the Grants Live

The demo's policy is the packaged host's `AdminPolicyAdapter` plus a
`ShowcasePolicy` module prepended to it (`tmp/demo/app/rails_ai_admin`). Read it
next to [Configuration]({% link _getting_started/configuration.md %}): each
feature above appears only because a method there returns `true` for the admin
role, and the articles resource opts in to AI proposals with
`assistant_changes :create, :update, :destroy`.
