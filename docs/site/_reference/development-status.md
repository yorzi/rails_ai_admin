---
layout: default
title: Development Status
nav_order: 5
guide: false
description: Current release scope, compatibility and remaining validation.
---

# {{ page.title }}

0.1.1 is the published Public Preview. This branch prepares 0.2.0; it has not been
released. See the [release history]({% link _reference/release-history.md %}) and
[upgrade guide]({% link _reference/upgrading.md %}).

0.2.0 focuses on Rails 8.1+ and simpler setup: generated authentication for Rails
and Devise, an opt-in trusted-staff policy, multiple and namespaced resource
generation, and compact navigation. The default policy stays closed. Full access
requires explicit opt-in and does not provide tenant scoping.

The engine already includes conventional CRUD, typed fields, associations, CSV
import/export, audit/history, dashboards and optional reviewed assistant changes.
The [0.1 overview]({% link _getting_started/whats-new-in-0-1.md %}) describes the
inherited capabilities. The repository's `COMPATIBILITY.md` distinguishes local,
packaged-host, browser and remote-CI evidence for each build.

Human screen-reader validation, an independent host trial and current live
provider verification remain open. Nested child forms, polymorphic writes,
association sorting, separate attach/detach grants, conversation retention and
token/cost budgets are future work. The assistant's deterministic tests use
synthetic responses and cannot establish live-provider behavior.

Owner review is required before publishing 0.2.0. Passing CI does not authorize a
release or establish production suitability for an arbitrary host.
