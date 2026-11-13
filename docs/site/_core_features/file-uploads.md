---
layout: default
title: File Uploads
nav_order: 15
description: Upload, replace, remove and download Active Storage attachments through the admin's own grants.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* How to declare a `file` field for a `has_one_attached` attachment and a
  `files` field for `has_many_attached`.
* How uploads are checked and where the bytes are stored.
* How downloads stay behind the record's grants.

## Declare a File Field

Your application must load Active Storage (`require "active_storage/engine"`,
`bin/rails active_storage:install`, a configured service). Declare the
attachment on the model as usual, then a `file` field with the same name:

```ruby
class Product < ApplicationRecord
  has_one_attached :photo
  has_one_attached :spec_sheet
end

class ProductAdmin < RailsAiAdmin::Resource
  model "Product"
  key :products
  title :name
  fields do
    text :name
    file :photo, accept: %w[image/png image/jpeg image/webp], max_size: 5.megabytes
    file :spec_sheet, accept: %w[application/pdf]
  end
end
```

Grant the field in `:read` to show it and in `:write` to upload, like any field.
`accept` lists content types (`image/*` matches every image type); without it
any type is accepted. `max_size` is in bytes and defaults to 10 MB. A `file`
field cannot search, sort or filter, and operation inputs cannot be files.

## Several Files

For `has_many_attached`, declare a `files` field:

```ruby
class Product < ApplicationRecord
  has_many_attached :gallery
end

# in ProductAdmin's fields block
files :gallery, accept: %w[image/*], max_size: 5.megabytes, max_files: 12
```

`accept` and `max_size` apply to each file; `max_files` (default 20, at most 100)
bounds the attached total. The edit form lists the current files, each with its
own "Remove" box, and a multiple file chooser that adds new ones. A save never
replaces the list as a whole: it removes the ticked attachments of this record
and attaches the new uploads, so files someone else added in the meantime are
kept. Removed files are detached in the write transaction and their blobs are
purged only after it commits. The record is touched, so its version advances and
the audit names the field.

Show pages render a gallery of links, with inline previews for raster images;
each link names its attachment (`?attachment=<id>`) and is checked like a single
file. Lists leave `files` out by default (`index: true` shows a count), CSV
export lists the filenames, and Chat sees names, types and sizes.

Through the Runner API, a `files` value is `{ "add" => [signed blob ids],
"remove" => [attachment ids] }`. New blobs must be unattached, as for `file`.

## Uploading

Forms with a writable file field are multipart. A chosen file is checked against
`max_size` before it is stored, then stored as a new Active Storage blob whose
content type Active Storage identifies from the bytes. The write itself goes
through the shared Operation Runner, which accepts only a new, unattached blob
that fits `accept` and `max_size`. If the write is refused, for example by a
validation error, the new blob is purged and the person chooses the file again.

An edit form shows the current file. Leaving the file box empty keeps it; the
"Remove the current file" box clears it when the field is not required. Pages
never accept a blob id typed into a file field, so a person cannot attach a
blob that was uploaded elsewhere. The audit names the field when the
attachment changes.

## Downloading

Pages link to `<admin>/<resource>/<id>/files/<field>`, never to a public Active
Storage URL. Each download checks the record's scope and show grant and a current
read grant for the field, then streams the file from the storage service with
`Cache-Control: no-store` and a sandboxed `Content-Security-Policy`.

Files download as attachments. PNG, JPEG, GIF, WebP and AVIF images may also be
shown inline, as the small preview on a record's page. SVG and HTML are never
shown inline, because they can carry script.
