---
layout: default
title: Upgrading
nav_order: 2
guide: false
description: Upgrade an existing 0.4 host to 0.5.0, update a layout override and add an assistant evaluation file.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

## Upgrade to 0.5.0

Set `gem "rails_ai_admin", "~> 0.5.0"` in your Gemfile and run these commands
from the host application.

```sh
bundle update rails_ai_admin
bin/rails rails_ai_admin:doctor
```

0.5.0 adds no migration. Install 0.4.1 and run its migration first if the host
is on 0.4.0 or earlier.

**Layout overrides.** The `layout` contract is revision 5. If you copied
`layouts/rails_ai_admin/application.html.erb`, the doctor reports it as
`STALE_CONTRACT`. Add `<%= admin_rich_text_assets %>` to its head and set the
header's `contract` to 5; see
[Template Overrides]({% link _advanced/template-overrides.md %}). Until then,
Trix keeps loading beside each editor, and an editor opened by a Turbo visit
can show its link dialog open.

**Prompt caching.** The assistant sends cache hints to the provider by default.
If your adapter points the `openai` provider at a compatible server that rejects
fields it does not know, set `config.assistant_prompt_caching = false`.

**Optional additions.** These are all opt-in:

* `instructions(context:)` on the assistant adapter, for operator notes.
* `config.assistant_fallback_models`, for up to three fallback models.
* `period` grouping, available for any date or datetime field the person may
  filter by. It needs no setup beyond that filter grant.
* An evaluation file. `bin/rails generate rails_ai_admin:assistant` writes
  `config/rails_ai_admin/assistant_eval.yml` when it is missing, and keeps your
  adapter and migrations; then run `bin/rails rails_ai_admin:assistant:eval`.

See [What's New in 0.5]({% link _getting_started/whats-new-in-0-5.md %}) and the
[Admin Assistant]({% link _advanced/admin-assistant.md %}) guide.

If you are upgrading from an earlier version, see the
[0.4.1 upgrade guide](https://github.com/yorzi/rails_ai_admin/blob/v0.4.1/docs/site/_reference/upgrading.md).
For a new installation, follow the [Quickstart]({% link _getting_started/quickstart.md %}).
