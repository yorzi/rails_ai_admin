---
layout: default
title: Review Surfaces
nav_order: 8
description: Save a native operation review as a persistent rails_tool_views Surface that confirms the same intent once.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* How to opt in when your application already uses rails_tool_views.
* What the admin does and does not change in the shared runtime.
* How a Surface confirmation relates to the native confirmation page.
* Which authorization checks apply and what is not available yet.

## Opt In

Admin review Surfaces build on the host's own rails_tool_views installation. Add
the gem to your Gemfile, run its installer migrations, then enable the admin
integration and choose the member operations that may be reviewed:

```ruby
# config/initializers/rails_ai_admin.rb
RailsAiAdmin.configure do |config|
  config.surfaces = true
end

class TicketAdmin < RailsAiAdmin::Resource
  # ...
  operation :triage, handler: "TriageTicketOperation", surface: true
end
```

Boot fails with a configuration error if `surfaces` is enabled but
rails_tool_views is not loaded. Without the opt-in, the admin loads no
rails_tool_views code and draws no Surface routes. `rails_ai_admin:doctor`
reports the state under `surfaces`.

## What the Admin Leaves Alone

Your rails_tool_views `scope_resolver`, `parent_controller`, `agent_adapter`,
`auto_deliver`, mount and registry reset hook stay yours. The admin adds one
component, `raa_operation_review`, and its own endpoints under your admin mount:

| Route | Purpose |
| --- | --- |
| `POST /:resource/:id/operations/:operation/surface` | Save the current native review as a Surface |
| `GET /assistant/surfaces/:id` | Render it with fresh authorization |
| `POST /assistant/surfaces/:id/actions` | Confirm it |

These endpoints pass an explicit admin scope (`raa:actor:...` and
`raa:tenant:...`) and never your resolver. The component's policy denies any
caller that is not one of these endpoints for the same authenticated admin, so
your product mount cannot read or confirm admin Surfaces. Admin endpoints cannot
open your product Surfaces either. If your `to_prepare` hook calls
`RailsToolViews.reset_registry!`, the admin component re-registers itself
on next use; its contract never changes between reloads.

## One Intent, Two Places to Confirm

After an operation form's preview, the confirmation page offers **Continue in
an interactive review**. That saves the exact intent and input as a Surface the
user can reload or come back to until the intent expires
(`config.intent_ttl`). Submitting the Surface's **Confirm and execute** form is
the human confirmation. It runs the same shared Runner on the same intent, with
audit origin `surface`.

Whichever place confirms first performs the write; the other replays the
recorded receipt and changes nothing. The business write, audit, outbox Work
and the Surface's new revision commit together. If the record changed, access
was revoked or the intent expired, the Surface records that outcome and asks for
a new review. If the operation itself fails, nothing is saved and the user can
try again.

## Authorization

Every render and confirmation re-checks the current record through your policy
scope and show permission, and the Runner re-checks the operation, input grant,
security version, expiry and record version as it does for the native page. A
completed review is a receipt: viewing it requires your
`read_operation_receipt?` grant, and it shows the recorded input. Surface
props hold only the intent reference and canonical input; they grant nothing.

## Let an Assistant Propose

Mark an operation `assistant: true` (it requires `surface: true`) and give your
RubyLLM chat the admin's proposal tool, built for the signed-in admin and a
conversation reference your server owns:

```ruby
require "rails_ai_admin/integrations/propose_operation"

tool = RailsAiAdmin::Integrations::ProposeOperation.new(
  context: admin_context, conversation: "raa:conversation:#{conversation.id}"
)
RubyLLM.context { |config| config.openai_api_key = credentials.fetch(:admin_openai_key) }
  .chat(model: "gpt-4.1-mini").with_tools(tool).ask(question)
```

The tool offers only opted-in operations on resources the user can list. When
the model proposes one, the server re-runs the normal preflight with the user's
current permissions and presents the same review Surface. The model is told that
nothing has changed; the review says an assistant proposed it. Only the user's
own **Confirm and execute** applies it, once. A provider retry of the same tool
call shows the same review instead of creating another. Keep provider settings
in `RubyLLM.context`; the admin never changes your global RubyLLM
configuration.

## Not Available Yet

The admin does not persist assistant chats yet, no AI follow-up or continuation
is delivered after confirmation, inputs cannot be edited inside the Surface, and
Surface templates are not in the override catalog. Close and retention of admin Surfaces are not
wired up. See the development status for the remaining AI milestones.
