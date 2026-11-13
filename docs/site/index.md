---
layout: home
title: Rails AI Admin
description: Build authorized admin pages with explicit resources and atomic operations.
permalink: /
hero:
  name: Rails AI Admin
  text: Explicit Rails administration
  tagline: A self-hosted Rails admin with everyday features, default-deny policies and one audited write path.
  actions:
    - theme: brand
      text: Get started
      link: /quickstart/
    - theme: alt
      text: Try the demo
      link: /demo/
features:
  - title: Explicit exposure
    details: Register reviewed resources and fields rather than publishing reflected models.
    link: /resources-and-fields/
    link_text: Declare resources
  - title: Host authority
    details: Resolve fresh sessions, complete tenant scopes and independent field permissions.
    link: /configuration/
    link_text: Connect policies
  - title: Atomic evidence
    details: Commit conventional domain changes, human confirmation, receipts and audit together.
    link: /operations/
    link_text: Understand operations
  - title: Everyday fields
    details: Text to JSON, uploads and galleries, rich text, many-to-many lists and write-only passwords.
    link: /resources-and-fields/
    link_text: See field types
  - title: Data in and out
    details: CSV export and checked imports, bulk delete, record history and an audit log, each behind its own grant.
    link: /csv-export/
    link_text: Move data
  - title: AI with a human in the loop
    details: Chat reads through your grants; every AI-suggested create, update or delete is a reviewed, audited, version-checked write.
    link: /admin-assistant/
    link_text: Meet the assistant
  - title: Overview at a glance
    details: Counts, metrics and daily trend charts, plus one search box across every resource.
    link: /dashboard/
    link_text: Build a dashboard
---

## Build Locally

This gem and documentation site are not published. In the checkout:

```sh
bundle install
bundle exec rake test
bundle exec rake build
```

The development package is `pkg/rails_ai_admin-{{ site.version }}.gem`. The
[ten-minute quickstart]({% link _getting_started/quickstart.md %}) takes an app with
Rails 8 sign-in to a working Users admin; the
[installation guide]({% link _getting_started/getting-started.md %}) connects other
hosts. It remains closed until you supply authentication and policies.

## A First Look

```ruby
class CustomerAdmin < RailsAiAdmin::Resource
  model "Customer"
  key :customers
  title :name
  fields do
    id :id
    text :name, nullable: false, required: true
  end
end
```

The declaration narrows exposure; it grants no permission. The host owns the model,
its tenant scope and every action/field decision. Writes detect concurrent edits
through `lock_version` or `updated_at` and share the domain's connection pool.

## See It Running

`bin/demo --assistant` serves a seeded admin on `127.0.0.1` with every feature
turned on: uploads, rich text, imports, history, charts, search, and AI chat and
MCP against an offline fake model. Open `http://127.0.0.1:3917/login` and click
**Sign in as Admin**. See
[Try the Demo]({% link _getting_started/demo.md %}).

## Extend Scalar Fields

[Field Types]({% link _core_features/field-types.md %}) shows class-name
registration, pure normalization/validation and field partials. The
[extension contract]({% link _reference/extension-contracts.md %}) records the
exact scalar/schema and rendering boundaries.
[Computed Fields]({% link _core_features/computed-fields.md %}) derives readonly
values from declared, recursively authorized scalar dependencies. Physical fields
keep their actual-attribute guard; neither extension grants additional authority.

## Customize Cataloged Templates

[Template Overrides]({% link _advanced/template-overrides.md %}) copies one
allowlisted page, layout or partial into the host without replacing existing
files. The [catalog]({% link _reference/template-catalog.md %}) specifies its
assigns/locals contract; doctor reports source/context drift for upgrade review.
Host edits still own their permission, escaping and confirmation behavior.

## Recover an Open Generic Form

[Form Session Recovery]({% link _advanced/form-recovery.md %}) can retain the
current create/update DOM after marked authentication/CSRF failure. Fresh sign-in,
manual Resume and explicit Save are required; refreshing or closing the page
loses this memory-only preservation.

## Return to a Current List

[List Navigation]({% link _core_features/list-navigation.md %}) carries bounded
search/sort/page hints through native record and operation flows, with fresh query
grants and bounded empty-page recovery. Return hints never choose an external
URL or grant record/list authority.

## Build a Host-Owned Admin Page

[Custom Controllers and Status Pages]({% link _advanced/custom-controllers.md %})
connects ordinary host Rails controllers/partials to fresh admin Context, explicit
scoped access and the shared Runner. Fixed status pages preserve HTTP/denial
boundaries without rendering normal resource navigation.

## Group Authorized Resources

[Resource Navigation]({% link _core_features/resource-navigation.md %}) supplies
static groups, plain labels, fixed icons and ordering for sidebar/Overview entries.
A hidden menu remains subject to the same direct route permissions; cosmetic
settings confer no record or operation authority.

## Current Scope

The current slice implements scalar CRUD, synchronous member operations and
durable post-commit delivery intent. Chat, trusted Surfaces, CSV, associations,
private files, global actions and larger asynchronous business workflows remain
future milestones.
Read [development status]({% link _reference/development-status.md %}) before treating
a target API in the plan as implemented.
