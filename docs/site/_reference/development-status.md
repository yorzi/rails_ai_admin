---
layout: default
title: Development Status
nav_order: 5
guide: false
description: Current release scope, compatibility and remaining validation.
---

# {{ page.title }}

0.2.0 is the current Public Preview. See the [release history]({% link _reference/release-history.md %}) and
[upgrade guide]({% link _reference/upgrading.md %}).

0.2.0 focuses on Rails 8.1+ and simpler setup: generated authentication for Rails
and Devise, an opt-in trusted-staff policy, multiple and namespaced resource
generation, and compact navigation. The default policy stays closed. Full access
requires explicit opt-in and does not provide tenant scoping.

The development branch prepares 0.3.0 for everyday list work: `contains`, `in`
and `blank` filters, sorting and searching by a reference, numbered pages, saved
views, one-step bulk actions with "all matching" up to 100 records, soft delete
with restore, and editing children from the parent page.
[What's New in 0.3]({% link _getting_started/whats-new-in-0-3.md %}) describes it.

The engine already includes conventional CRUD, typed fields, associations, CSV
import/export, audit/history, dashboards and optional reviewed assistant changes.
[What's New in 0.2]({% link _reference/whats-new-in-0-2.md %}) describes this
release, and [What's New in 0.1]({% link _reference/whats-new-in-0-1.md %}) the
inherited capabilities. The repository's `COMPATIBILITY.md` distinguishes local,
packaged-host, browser and remote-CI evidence for each build.

Human screen-reader validation, an independent host trial and current live
provider verification remain open. Editing children inside the parent's form in
one save, polymorphic references, bulk actions over more than 100 records,
separate attach/detach grants, conversation retention and token/cost budgets are
future work. The assistant's deterministic tests use
synthetic responses and cannot establish live-provider behavior.

Passing CI does not establish production suitability for an arbitrary host.
