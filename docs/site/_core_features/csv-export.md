---
layout: default
title: CSV Export and Import
nav_order: 14
description: Download the list you are looking at as CSV, and create records from a CSV file, through the same grants as the pages.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* How to show the Export CSV button.
* Which rows, columns and values the file contains.
* How exports are bounded and audited.
* How to create records from a CSV file.

## Turn It On

Export is default-deny. With a custom adapter, grant it per resource:

```ruby
def export_records?(context:, resource:)
  resource.key == :orders && context.actor.admin?
end
```

With the Pundit adapter, add `export_records?` to the resource's policy:

```ruby
def export_records? = user.actor.admin?
```

The list page then shows an **Export CSV** button. It submits a POST with the
CSRF token, so a link on another site cannot start a download, and each export
writes an audit event.

## What the File Contains

The file holds every record of the current list across all its pages: the same
search, list tab, filters and sort, inside your policy scope. Pagination is
ignored. A record whose own `show` check fails is left out, as on the list page.

Columns are the fields the actor may read on the show page, in declaration
order, with their labels as the header. Values are written for reading in a
spreadsheet:

* Dates and timestamps are ISO 8601, timestamps in the context's time zone.
* Decimals keep their exact digits; select fields use their labels.
* A `belongs_to` field is the target's label, through the target's own grants.
* `json` fields are compact JSON. A `password` field never appears.
* Registered field types use their formatter, so a redacting formatter stays
  redacted.

A text cell that starts with `=`, `+`, `-`, `@`, a tab or a carriage return gets
a leading apostrophe, so a spreadsheet cannot run it as a formula. The file is
UTF-8 with a byte order mark and CRLF line endings.

## Bounds and Audit

`config.export_limit` caps the rows in one file (default 10,000, at most
100,000). A larger list redirects back with a notice asking the person to narrow
it with search or filters. Records are read 500 at a time.

Each export records an audit event with operation `export`, no record id, and
the exported field names in `changed_fields`. The response is sent with
`Cache-Control: no-store`.

## Importing Records

A separate default-deny grant, `import_records?(context:, resource:)` (Pundit:
`import_records?`), together with the resource's ordinary `create` grant, adds an
**Import CSV** button. The import page lists the columns it understands and offers
a template with that header row.

Use the template for the fields the actor may write on create. The importer
accepts an exact field name or an unambiguous label. When a header matches
multiple fields, the template uses the exact field name. Unknown columns are
reported and ignored.

Supported values include text, numbers, dates, times, email, URLs, select and
enum values, JSON, rich text and `belongs_to` keys. For booleans, use `Yes` or
`No`, `true` or `false`, or `1` or `0`. Select fields accept their labels or
values. Dates and times use ISO format. An empty cell leaves the field at its
default. When reusing an export, copy the writable columns into the template
and supply target keys for any `belongs_to` columns.

### Review a file before creating records

Choose **Review CSV import** for up to the configured import limit. A host without background identity resolution or the import-rows migration can review up to 100 rows. Match unfamiliar headers to writable fields or choose **Ignore column**. The first three values from each column help identify it. Rows report validation errors and flag cells beginning with spreadsheet formula characters.

To check for duplicates, choose a mapped field that your policy allows you to filter by equality. The preview checks the current policy scope and earlier included rows in the file. Choose **Skip duplicate rows** or **Create a new record**. Exclude any other rows you want to leave out, then choose **Update preview**. The selected rows must all pass validation before you can confirm. Confirmation rechecks the preview and creates the selected records together through the native create operation. If the preview changed, reopen the draft and review it again. Repeating a successful confirmation shows the same result.

The review is private to the current actor, tenant and security version and expires after 30 minutes. Rails stores the uploaded CSV encrypted and discards it when confirmation succeeds. Schedule the existing `rails_ai_admin:prune` task to remove expired drafts.

With assistant access, you can choose **Suggest column mapping with AI**. This sends up to 50 headers and up to 50 writable field definitions (names, labels and types) to the host's configured provider. Data rows stay on the host. Review the suggested fields and formatting hints, then choose **Update preview** to apply your choices.

If the host enables assistant Surfaces, ask chat to “open my latest CSV import for articles” after uploading a draft. The card shows how many rows are selected and how many need correction. **Open import review** returns to the native form for edits and confirmation. Only the card reference goes to the model.

### Check a file or import a larger file

**Check file** checks types, references, create policy and model validations using the template headers. Confirming more than 100 selected rows queues an import. Workers re-resolve the operator and check permissions, duplicate matches and field contracts on each row. Each committed create and its progress marker share a transaction. Refresh the review for progress, download failed rows, or retry just those rows under current grants. Schedule `bin/rails rails_ai_admin:imports:scan` to recover missed job deliveries. Admitted batches stay available for 24 hours. The **Import** button uses the synchronous direct importer. It processes each row independently and reports the first 100 failures. Hosts that have yet to install the draft migration also use this workflow.

Upload UTF-8 CSV of at most 2 MB. Quote cells containing commas or line breaks
and double any quotation mark inside a quoted cell. The whole file is parsed
before import begins. `config.import_limit` bounds the data rows (default 500,
at most 5,000).
