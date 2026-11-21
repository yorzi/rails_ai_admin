---
layout: default
title: Try the Demo
nav_order: 5
description: Run one seeded local admin and follow a tour from editing records to reviewing assistant changes.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* How to run the demo without an API key.
* How to manage records, review an assistant proposal and find the audit event.
* How to check the same admin with different permissions or connect an MCP client.

## Start the Demo

From a checkout:

```sh
bundle install
bin/demo
```

Open [http://127.0.0.1:3917/login](http://127.0.0.1:3917/login) and choose **Sign in as Admin**. The demo copies the session/SQLite host to `tmp/demo`, installs and seeds it, and uses a scripted local model on port 3918. Neither Chat nor MCP needs an API key. Both servers bind to loopback. Ctrl-C stops them, and restarting the demo resets the sample data and conversations.

## 1. Find and Edit an Article

Start on **Overview** for resource counts, metrics and charts. Search for `upgrading` in the header to see [global search]({% link _core_features/dashboard.md %}), or open **Articles** for a single resource.

![The admin overview with article and order metrics and an article trend chart]({{ '/assets/images/screenshots/overview.png' | relative_url }})

On **Articles**, try the **Popular** list tab or **Filters → Contact contains** with `editor1`. Use **Save this view** to keep that filter, or **Export CSV** to download the filtered list. Reset the list, open **Article 1: Getting started**, then choose **Edit**. Change **Views** to `42` and save. The **Content** tab has a rich text editor, a cover upload and a gallery. **Publishing** has JSON, tags and a write-only password. The record page links to its associated summary. For a customer picker, open a draft **Order** and choose **Edit**.

![The article edit form showing the Content tab with a rich text editor, cover upload and gallery]({{ '/assets/images/screenshots/form.png' | relative_url }})

## 2. Review an Assistant Change

Open **Assistant → New conversation**. The offline model recognizes the exact phrases below and streams a reply.

| Type this | What to check |
|---|---|
| `search articles for upgrading` | The results link to the matching records. |
| `sum orders total by state` | The assistant reports a total for each visible order state. |
| `sum orders total by week of delivery_on` | Weekly totals, oldest first, with empty weeks and undated orders shown. |
| `set articles 1 title to Hello` | The card shows before and after. Choose **Confirm and execute** to save, or **Dismiss** to leave the article unchanged. |
| `set customers points to 50 for Bulk` | One review lists all 30 matching customers. Open it to inspect each change and choose **Update 30 records** to apply it. |

![An assistant conversation with a proposed article title change and confirmation controls]({{ '/assets/images/screenshots/assistant.png' | relative_url }})

![A bulk review preview showing customer points before and after the proposed update]({{ '/assets/images/screenshots/bulk-review.png' | relative_url }})

After confirming the title change, open the article's **History** to see which field changed and that the update came from a review in Chat. The history does not store field values. Open **Audit log** to see the actor, record and outcome across changes and exports. The conversation shows token usage over the last 24 hours against the demo's limit.

![Article history showing an update from Chat and an earlier edit through the form]({{ '/assets/images/screenshots/history.png' | relative_url }})

## 3. Try More in the Same Demo

* **Import and restore:** In **Articles → Import CSV**, select `tmp/demo/articles-import.csv`. **Check file** previews the rows without writing; **Import** creates the two valid articles and reports the invalid row. Back on the list, select two articles, choose **Delete selected**, and confirm. Open **Deleted records** to restore them. See [CSV Export and Import]({% link _core_features/csv-export.md %}).
* **Custom actions:** Open a draft **Order** to use its **Review order** action. In **Customers**, select two customers, choose **Award points to selected customers**, then review and queue it. Refresh the job page to see each customer's outcome. This is a [queued collection operation]({% link _core_features/collection-operations.md %}), not the synchronous assistant bulk review. The demo runs these jobs in the web process; it is not a production queue setup.
* **Concurrent edits:** Open the same article's edit form in two tabs. Change a value and save in the first tab, then try to save a different value from the second. The second save stops rather than overwriting the first.
* **Permissions:** Sign out and choose **Viewer**. It sees Tenant A records but has no edit, audit or assistant controls. Sign in as **Other tenant** to see Tenant B's customer and order instead of Tenant A's data. Both comparisons use the same app and policy.
* **MCP:** As Admin, open **MCP access**, issue a demo token and connect to `http://127.0.0.1:3917/staff/mcp` as described in the [MCP Server guide]({% link _advanced/mcp-server.md %}). Start with `list_resources` or `count_records` on `articles`. A write proposal returns a browser review URL, not a completed write. Revoke the token when done.

## Use a Real Model (Optional)

Run `bin/demo --openrouter` to change only the model provider. Load `OPENROUTER_API_KEY` into the environment before starting. The key is not written to the demo files. The default model is `openai/gpt-6-luna`; set `RAA_DEMO_MODEL` to choose another. Real requests cost money and the demo checks a daily limit of US$0.25 per person. Without a key, Chat cannot call the model; the rest of the admin still works.

For a different port, run `bin/demo --port 4000`. The host and CSV file are then in `tmp/demo-4000`, and the offline model uses port 4001. Use `--setup-only` to build that same host without starting either server.
