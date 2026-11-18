---
layout: default
title: Upgrading
nav_order: 2
guide: false
description: Upgrade an existing host to 0.4.1 and apply the bulk review migration.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

## Upgrade to 0.4.1

Set `gem "rails_ai_admin", "~> 0.4.1"` in your Gemfile and run these commands
from the host application.

```sh
bundle update rails_ai_admin
bin/rails generate rails_ai_admin:install --skip
bin/rails db:migrate
bin/rails rails_ai_admin:doctor
```

The installer copies `add_bulk_change_decision_to_rails_ai_admin_selections`.
Run the migration before serving bulk review requests with the new code.
Confirmations now use a signed set of the records offered on the review page.
Reload any bulk review page opened before the upgrade before submitting it.
If your application overrides the bulk review template directly, update it to
submit the current `review_signature` field and an explicit `decision`.

Joined policy scopes count each record once in lists and bulk selections.
CSV checks run the model validations and create policy against the populated
record. Download a fresh template if your CSV contains labels that match
several fields. The [CSV guide]({% link _core_features/csv-export.md %}) explains
how to resolve those columns.

If you are upgrading from an earlier version, see the
[0.4.0 upgrade guide](https://github.com/yorzi/rails_ai_admin/blob/v0.4.0/docs/site/_reference/upgrading.md).
For a new installation, follow the [Quickstart]({% link _getting_started/quickstart.md %}).
