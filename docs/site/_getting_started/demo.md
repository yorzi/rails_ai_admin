---
layout: default
title: Try the Demo
nav_order: 5
description: Run a seeded local admin with every feature turned on, from a checkout of this repository.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* How to start the demo and sign in.
* Where to find each feature in it.
* How the demo grants map to your own policy.

## Start It

From a checkout, after `bundle install`:

```sh
bin/demo
```

The script copies the packaged session/SQLite host to `tmp/demo`, points it at
this checkout, installs Active Storage and Action Text, migrates and seeds a fresh
database, and serves it on `127.0.0.1:3917` only. Every run starts from scratch;
press Ctrl-C to stop the server.

Sign in at `http://127.0.0.1:3917/login` with one of these accounts (password
`demo-password`):

| Account | Sees |
|---|---|
| `admin@example.test` | Everything in Tenant A, with writes, imports, exports, history and the audit log |
| `viewer@example.test` | Tenant A read-only: lists, records and search; no passwords or write pages |
| `other@example.test` | Tenant B, which has almost no data: tenant scoping at work |

Options:

* `--plain` leaves out the articles showcase and keeps the packaged customers and
  orders only.
* `--assistant` adds admin Chat against an offline fake provider, with no API
  key or network. On an article page, **Ask the assistant about this record**
  with `set articles 1 title to Hello`: a review shows the title before → after,
  and only **Confirm and execute** saves it. `history of articles 1`,
  `create articles with title Draft` and `delete articles 2` work the same way.
  Replies stream in a few characters at a time. **MCP access** in the menu
  issues a token for connecting Claude Code or another MCP client to the demo.
* `--port 4000` changes the port; `--setup-only` prepares `tmp/demo` without
  serving it.

## A Tour

* **Overview**: resource cards with counts, then metrics and 30-day trend charts
  for orders and articles. See [Dashboard and Search]({% link _core_features/dashboard.md %}).
* **Search everything**: the header box searches customers, articles, tags and
  orders at once.
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

## Where the Grants Live

The demo's policy is the packaged host's `AdminPolicyAdapter` plus a
`ShowcasePolicy` module prepended to it (`tmp/demo/app/rails_ai_admin`). Read it
next to [Configuration]({% link _getting_started/configuration.md %}): each
feature above appears only because a method there returns `true` for the admin
role.
