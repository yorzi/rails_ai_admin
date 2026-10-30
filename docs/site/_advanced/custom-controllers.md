---
layout: default
title: Custom Controllers and Status Pages
nav_order: 7
description: Build host-owned Rails pages with fresh admin context, explicit scoped access and fixed status presentation.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* How a host controller shares admin authentication and execution boundaries.
* How to keep host and mounted-engine routes distinct.
* How fixed status pages preserve denial and recovery behavior.
* Which security and error-handling responsibilities remain with the host.

## Start With a Host-Owned Controller

Given a registered `CustomerAdmin` resource with current host policies, define
`app/controllers/customer_workbench_controller.rb`:

```ruby
class CustomerWorkbenchController < RailsAiAdmin::CustomController
  def show
    access = admin_access(:customers)
    record = access.find!(params[:id])
    @values = access.project(record, view: :show)
    @engine_record_path = admin_routes.resource_path(
      resource: access.resource.key, id: record.id
    )
  end
end
```

`admin_access` resolves a registered resource; it does **not** grant an action.
Use `authorize!`, scoped `find!`/`relation` and permitted `project` values explicitly.
This example's find requires current show access and tenant scope; its projection
also applies current show-view/read/dependency grants. Do not call unscoped model
finders or display extra record attributes in a custom view.

Inside the host's normal `Rails.application.routes.draw` block:

```ruby
get "/workbench/customers/:id", to: "customer_workbench#show"
```

The host owns this route, controller, views and partials. The base uses
`layout false`; it does not select the host's application layout automatically.
For `app/views/customer_workbench/show.html.erb`:

```erb
<h1>Customer workbench</h1>
<%= render "card", values: @values %>
<%= link_to "Host home", root_path %>
<%= link_to "Native record", @engine_record_path %>
```

For `app/views/customer_workbench/_card.html.erb`:

```erb
<% if values.key?("name") %><p><%= values.fetch("name") %></p><% end %>
```

This is ordinary Rails partial lookup and escaping. A hidden name produces no
name output. Choose a host layout explicitly if needed, preserving CSP/CSRF and
normal escaping; copying a template is not authorization.

## Use the Protected Admin Entry Points

The base inherits the admin's fresh Context resolution on each request, CSRF
protection, security headers and action-parameter filtering. It does not inherit
host `ApplicationController` concerns or before-actions automatically. Keep the
host Context adapter responsible for the actual session/Warden/tenant contract.

| Protected controller API | Meaning |
| --- | --- |
| `admin_context` | Authenticated current Context; no implicit system actor |
| `admin_access(registered_key)` | Resource Access object; no action grant |
| `admin_operation_runner` | Same Operations::Runner used by native CRUD/member workflows |
| `admin_routes` | Mounted engine route proxy, also available in views |
| `admin_csp_nonce` | Immutable copy of this response's prepared CSP nonce, also available in views |
| `admin_status(kind)` | Fixed status rendering; does not halt the action |

These protected methods are not additional routable actions. For writes, use
`admin_operation_runner` with the current `admin_context`, explicit resource/
operation/target binding and the same prepare/preflight/confirmation contract
from [Operations]({% link _core_features/operations.md %}). A host form supplies
CSRF and deliberate human confirmation; controller inheritance does not authorize
an arbitrary save or bypass field/version/receipt/audit checks. This API does not
replace CRUD handlers or execute a custom command without its registered grant.

A custom layout that loads the prebuilt admin JavaScript bundle must include:

```erb
<meta name="csp-nonce" content="<%= admin_csp_nonce %>">
```

The base prepares the matching response CSP header; Turbo uses this nonce for
its injected progress-bar stylesheet. Do not invent a nonce or weaken the policy
with unsafe-inline. A layout that loads no JavaScript does not need this meta
for Turbo; the minimal read-only example above does not load the bundle.
The helper is protected, available in views and fails if security headers have
not yet been prepared.

## Keep Host Helpers and Engine Helpers Explicit

In this host controller, unqualified `root_path` stays the host root. Use
`admin_routes.resource_path(...)` and other proxy methods for engine links; they
respect the actual single named host mount and request SCRIPT_NAME prefix. Do not construct
engine paths by concatenating a hardcoded `/backoffice` prefix or use a client
return URL to choose a destination.

To place an optional host-owned custom route **under the engine prefix**, register
it in an initializer before the engine route set is drawn, for example
`config/initializers/admin_workbench_routes.rb`:

```ruby
RailsAiAdmin::Engine.routes.prepend do
  get "workbench/customers/:id", to: "/customer_workbench#show"
end
```

The leading slash selects the host controller rather than an engine-namespaced
controller. This route still uses that host controller's own view/layout/helper
context. Register the prepend during initialization, not as a late mutation in
host config/routes or through a monkeypatch. Keep the custom path distinct from
native resource routes and use the public mounted proxy for native engine URLs.

The engine middleware filters initial request-URL query values only for its
recognized named mount prefix. A custom page outside that prefix still receives
action-parameter filtering, but its initial Started URL logging is the host's
responsibility. Prefer an engine-prefix custom route when relying on the default
URL-redaction boundary. Host SQL/debug/explicit logging remains host-owned in
either case.

## Inspect the Packaged Order Workbench

The checkout's native-session consumer includes a separate Order domain at
`spec_hosts/session_sqlite/`. Its engine mount is `/staff`; initializer
`config/initializers/order_review_routes.rb` exposes the host-owned
`/staff/workbench/orders/:id` flow. Source paths below are relative to that host:

* `app/rails_ai_admin/order_admin.rb` registers the native resource and
  `app/rails_ai_admin/review_order_operation.rb` supplies its review command.
* `app/controllers/order_reviews_controller.rb` subclasses CustomController and
  uses the same command through admin_access/admin_operation_runner/admin_routes.
* `app/views/order_reviews/` and `app/views/layouts/order_review.html.erb` are
  ordinary host views, partials and an explicitly selected layout.

Orders exercise exact decimal total, date delivery and false Boolean input with
normal model validation. State/review context is readonly in generic forms;
review_note is readable only by the admin role and secret_payment_token is hidden.
Current tenant scope and role decisions still govern the workbench. After review,
the draft-only update/destroy predicate denies further generic mutation, while
independent receipt permission can read the original review result.

The packaged acceptance source, `test/acceptance_test.rb`, covers a workbench
input-bound preview, execution through the native review endpoint and replay
through the workbench with one original business audit/version transition. It
also covers stale-version/changed-confirmed-input rejection, tenant/role denial
and projected content without the payment token. The two UIs share execution
identity and policy rather than implementing separate domain writes. Its preview
form explicitly uses `data: { turbo: false }` for an ordinary Rails POST returning
200 HTML confirmation; it does not ask Turbo to treat that response as a redirect.
Successful confirmation POST returns 303.

The packaged reload probe replaced the host controller, resource, operation and
registry, observed the new HTTP header and rejected the old version-1 approval
after version 2 with 409 and no business write. The host's production eager-load
check and render probe for every current catalog entry also passed.

A Chrome check exercised a draft order's workbench preview with normalized note,
then explicit confirmation produced approved state with one audit/version
transition and no JavaScript/CSP errors. A separate generic Order form retained
total 45.67, delivery 2026-11-06 and expedited false across a second-tab session
rotation, marked CSRF 422, paused Save and manual Resume with the same UUID.
Local/session storage stayed empty; explicit Save committed once. Approved edit
returned a minimal 404 without order content or resource navigation. A 390px
dark-mode workbench check showed no horizontal overflow.

This remains author-controlled packaged/browser evidence. It establishes no
Surface/AI/provider integration, independent adoption, complete accessibility
review or full release readiness. Broader Phase 2 DSL filters/scopes/navigation
work and the full release Gates remain open.

## Render a Fixed Status and Return

Host actions can explicitly select one of eight status kinds. For a deliberate
host page-level denial, use **`return admin_status(:forbidden)`**. Like Rails
`render`, `admin_status` does not stop subsequent action code; returning is
necessary before any later business work. Do not blanket-convert record denials
to 403: normal unknown/forbidden records retain the same anti-enumeration 404.

The fixed kinds are authentication_required (401), forbidden (403), not_found
(404), conflict (409), invalid_query/invalid_request (422), unavailable (503) and
error (500). See [Extension Contracts]({% link _reference/extension-contracts.md %})
for exact codes. The input is only the known kind, not an exception, record,
business value, arbitrary message or custom return URL. `Presentation::Status`
provides immutable fixed text snapshots; error text also cautions that a prior
write may have completed.

HTML and Turbo requests render the dedicated minimal status layout/page as HTML
with `turbo-visit-control: reload`. It has no ordinary resource navigation or
registry-dependent menu. Authentication status may show only the configured
fixed internal sign-in path. Non-HTML requests retain plain status text; this is
not a new JSON API.

If a host status override fails, rendering falls back to the fixed plain message
with the same HTTP status and any session-recovery marker. A failure cannot
claim recovery is ready. The fallback hides the failed template's diagnostics
rather than rendering them into the response. Preserve these boundaries when
copying the `status_layout`/`status_page` catalog entries.

Only these explicit rendering/known denial/configuration/CSRF paths are covered.
There is no blanket rescue of arbitrary action exceptions and no replacement of
the host's exceptions_app. Unhandled host action errors still belong to its own
Rails error handling and operational review.

## Next Steps

* [Extension Contracts]({% link _reference/extension-contracts.md %}) records controller/status signatures and fixed kinds.
* [Template Overrides]({% link _advanced/template-overrides.md %}) explains status template metadata and fallback responsibilities.
* [Operations]({% link _core_features/operations.md %}) preserves the shared business execution boundary.
