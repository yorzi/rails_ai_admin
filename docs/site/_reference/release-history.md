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
| 0.2.0 (unreleased) | Rails 8.1+; generated authentication, opt-in full access, multi-model registration and compact navigation. |
| 0.1.1 (Public Preview) | Clearer navigation, typography, and introductory documentation. |
| 0.1.0{% if site.docs_unreleased %} (Public Preview candidate){% else %} (Public Preview){% endif %} | [What's New in 0.1]({% link _getting_started/whats-new-in-0-1.md %}) |
