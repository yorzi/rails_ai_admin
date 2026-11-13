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

Columns are the fields the actor may write on create, matched by label or name,
ignoring case. Unknown columns are reported and ignored. Text, numbers, dates,
times, email, URL, select, enum, JSON, rich text and `belongs_to` keys can be
imported; files, passwords and `references` lists cannot. Cells are read the way
export writes them: `Yes`/`No` (or `true`/`false`, `1`/`0`) for booleans, labels
or values for select fields, ISO dates and times. An empty cell leaves the field
to its default. A file exported from the same list therefore imports back,
except that `belongs_to` columns need the target's key rather than its label.

**Check file** validates every row (types, required values, references the actor
can see) and writes nothing. **Import** then creates one record per valid row
through the native create operation: each row has its own policy check, model
validations, transaction and audit event, so one bad row never stops the others.
The results list every row that was not created and why.

The file must be UTF-8 CSV (a byte order mark is fine) of at most 2 MB, with
quoted cells per RFC 4180. `config.import_limit` bounds the data rows (default
500, at most 5,000); import runs in the request, so keep files small.
