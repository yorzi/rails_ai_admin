---
layout: default
title: Upgrading
nav_order: 2
guide: false
description: Upgrade an existing host to 0.3.0 and install the saved views migration.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

## Upgrade to 0.3.0

0.3.0 adds one engine table for saved views. Copy the new migration and run it:

```sh
bin/rails generate rails_ai_admin:install --skip
bin/rails db:migrate
```

Until then the list works as before without the Saved views panel, and
`rails_ai_admin:doctor` reports saved views as closed. There is no
configuration change. Check these if they apply:

* **Copied index template.** `resource_index` is now revision 9 and receives
  `@bulk_destroy`, `@bulk_operations`, `@saved_views` and `@deleted_records`. Doctor reports the copy for review.
  Move it aside, run `bin/rails generate rails_ai_admin:override resource_index`
  (the generator never overwrites a host file) and reapply your changes, or
  your list keeps the old two-step **Capture selection** bar.
* **Tests that look for "Capture selection".** The button is now **Review
  selection**, and a bulk delete with nothing deletable redirects to the
  selection (303) instead of returning 404.
* **New filters.** `contains` and `blank` are opt-in per field, for example
  `email :contact, filterable: %i[contains blank]`, and still need the actor's
  `filter` grant. See [Typed Filters]({% link _core_features/typed-filters.md %}).

For changes required by earlier versions, see the
[0.2.0 upgrade guide](https://github.com/yorzi/rails_ai_admin/blob/v0.2.0/docs/site/_reference/upgrading.md).
For a new installation, follow the [Quickstart]({% link _getting_started/quickstart.md %}).

Review the [Public Preview limits]({% link _getting_started/whats-new-in-0-3.md %}#public-preview-limits)
and run the host's authentication and authorization tests before deploying.
