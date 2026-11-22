---
layout: default
title: Release History
nav_order: 3
guide: false
description: Find release notes and installation instructions for each documentation version.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

{% if site.docs_unreleased %}
This is the development documentation. Use the source installation in
[Getting Started]({% link _getting_started/getting-started.md %}).
{% endif %}

| Version | Notes |
| --- | --- |
| 0.4.1 (Public Preview, 2026-11-18) | [Release notes](https://github.com/yorzi/rails_ai_admin/releases/tag/v0.4.1). Single-use bulk reviews, distinct list counts, stricter CSV imports and cleanup for rejected uploads. [Apply the new migration]({% link _reference/upgrading.md %}). |
| 0.4.0 (Public Preview, 2026-11-15) | [What's New in 0.4]({% link _reference/whats-new-in-0-4.md %}): assistant totals, one reviewed change for many records, spending limits, conversation retention and tests recorded with real models. |
| 0.3.0 (Public Preview, 2026-11-14) | [What's New in 0.3]({% link _reference/whats-new-in-0-3.md %}): richer list filters, reference sorting, saved views, bulk actions and soft delete with restore. |
| 0.2.0 (Public Preview) | [What's New in 0.2]({% link _reference/whats-new-in-0-2.md %}): Rails 8.1+; generated authentication, opt-in full access, multi-model registration and compact navigation. |
| 0.1.1 (Public Preview) | Clearer navigation, typography, and introductory documentation. |
| 0.1.0 (Public Preview) | [What's New in 0.1]({% link _reference/whats-new-in-0-1.md %}) |
