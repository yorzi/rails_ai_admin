---
layout: default
title: Upgrading
nav_order: 2
guide: false
description: Review development contract and storage changes before replacing a local build.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

No stable gem has been released. Development APIs and migrations can still change;
read the checkout's `CHANGELOG.md` and public contract before replacing a local build.
Do not infer that an unchanged `0.1.0.dev` identifier guarantees compatible storage.

Back up the host database, test migrations against a disposable copy, run the host
policy matrix and verify packaged installation before using a changed build.
Never delete live operation receipts to get a replay to execute again. Keep
pending/unknown outcomes and the full supported retry window intact.

A future stable release must document SemVer, supported combinations, migration
and rollback limits, release notes and explicit owner approval. This page does not
approve deployment or publication.
