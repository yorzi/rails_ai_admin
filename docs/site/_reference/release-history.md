---
layout: default
title: Release History
nav_order: 3
guide: false
description: Distinguish the unreleased development build from future published releases.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

There is no published release yet. The current development identifier is
`{{ site.version }}` and `released` remains false.

The local build script renders the working tree at the configured root until a
release tag containing the documentation exists. It can later render the latest
release at `/`, development at `/next/` and older major documentation at `/vN/`.
No remote repository, GitHub Pages deployment or RubyGems publication is implied
by these build conventions.
