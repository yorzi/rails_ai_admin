---
layout: default
title: Configuration
nav_order: 3
description: Connect host sessions and explicit policies without granting implicit access.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* How to construct a fresh authenticated context.
* How to scope records and grant actions and fields independently.
* How to configure mounts and bounded form intents.

## Resolve an Authenticated Context

Installation generates a closed `AdminContext` and a default-deny
`AdminPolicyAdapter`; neither automatically connects your existing authentication.
A context adapter implements one public method, `resolve(controller)`. It returns
a `RailsAiAdmin::Context` or `nil`. This example assumes a host `User` with an
`account`, `role` and `security_version`; the gem does not supply these models.

```ruby
# app/rails_ai_admin/admin_context.rb
class AdminContext
  def resolve(controller)
    user = User.find_by(id: controller.session[:user_id])
    return unless user

    RailsAiAdmin::Context.new(
      actor: user,
      tenant: user.account,
      security_version: user.security_version,
      time_zone: "UTC"
    )
  end
end
```

Use the host's session or authentication API. Do not trust actor or tenant IDs
submitted as admin form fields. Both objects need a stable `id` and named class.
References include the `raa:` namespace, type and key. `Context` keeps no global
Current state or provider credentials.

The host must change `security_version` when the authority associated with an
existing session changes. Every request resolves authority again; a previously
issued intent does not override a changed session, role or tenant.

## Grant Scoped Actions and Fields

A custom adapter implements `scope`, `allowed?` and `fields` for conventional CRUD.
Registered custom commands also require the independent input/receipt/delivery
grants described in [Operations]({% link _core_features/operations.md %}). This example grants
reads to host users and writes to an `admin` role within their current account:

```ruby
# app/rails_ai_admin/admin_policy_adapter.rb
class AdminPolicyAdapter < RailsAiAdmin::Authorization::Adapter
  def scope(context:, resource:, relation:)
    relation.where(account_id: context.tenant.id)
  end

  def allowed?(context:, action:, resource:, record: nil)
    return true if %i[index show].include?(action)
    %i[create update destroy].include?(action) && context.actor.role == "admin"
  end

  def fields(context:, resource:, action:, record: nil)
    case action
    when :read
      %i[id name points active]
    when :write
      context.actor.role == "admin" ? %i[name points active] : []
    when :search, :sort
      %i[name]
    else
      []
    end
  end
end
```

For several resource models, branch explicitly on `resource.key`; do not assume
every model has `account_id` or identical fields. Action grants must return the
boolean `true`. Unknown resources and forbidden records use the same 404 response.
Missing authentication returns 401.

The scope must be a **complete filter relation** of the resource's model. Supply
membership conditions with `where`, joins and equivalent filters. Do not put
`limit`, `offset`, `select`, `group`, `having` or `from` in a policy scope; the
framework rejects these shapes rather than widening their membership during
pagination or member lookup. A SQL scope must already represent all readable
records; filtering unauthorized rows after pagination is not equivalent.

Field grants are independent for `:read`, `:write`, `:search` and `:sort`. Each is
intersected with the declared resource fields. Search and sort also require their
DSL flags; write also requires the field to be editable for the operation. Hiding
a field in a template does not establish authorization. You can instead opt into
the [Pundit adapter]({% link _advanced/pundit-and-devise.md %}) with an explicit policy
for each resource. ActionPolicy integration remains future work.

### Optional Grants

Every other capability has its own default-deny method. Implement only the ones
you use; each still needs the ordinary action and field grants.

| Method | Turns on | Guide |
|---|---|---|
| `filter` in `fields` | Typed list filters | [Typed Filters]({% link _core_features/typed-filters.md %}) |
| `named_scopes(context:, resource:)` | List tabs and dashboard metrics over them | [Named Scopes]({% link _core_features/named-scopes.md %}) |
| `select_records?(context:, resource:)` | Index checkboxes, fixed selections, bulk delete | [Fixed Selections]({% link _core_features/selections.md %}) |
| `export_records?(context:, resource:)` | Export CSV | [CSV Export and Import]({% link _core_features/csv-export.md %}) |
| `import_records?(context:, resource:)` | Import CSV (with `create`) | [CSV Export and Import]({% link _core_features/csv-export.md %}) |
| `view_history?(context:, resource:, record:)` | A record's History page | [Record History]({% link _core_features/record-history.md %}) |
| `view_audit_log?(context:, resource:)` | The Audit log page | [Record History]({% link _core_features/record-history.md %}) |
| `operation_fields`, `read_operation_receipt?`, `deliver_work?`, `cancel_operation?` | Custom operations and their receipts | [Operations]({% link _core_features/operations.md %}) |
| `assistant?(context:, resource:)` | Admin Chat for the resource | [Admin Assistant]({% link _advanced/admin-assistant.md %}) |
| `presentation_fields(context:, resource:, view:, record:)` | Per-view narrowing of fields | [Resources and Fields]({% link _core_features/resources-and-fields.md %}) |

With the Pundit adapter, the same names are methods on each resource's policy
(for example `def export_records? = user.actor.admin?`).

## Configure Before Boot

```ruby
RailsAiAdmin.configure do |config|
  config.context_adapter = "AdminContext"
  config.authorization_adapter = "AdminPolicyAdapter"
  config.resources = ["CustomerAdmin"]
  config.title = "Operations"
  config.intent_ttl = 15.minutes
  config.environment_label = "Staging"        # optional header badge
  config.validation_messages = :model         # or :generic
  config.queue_name = "rails_ai_admin"        # Active Job queue for admin jobs
end
```

`intent_ttl` accepts 60 through 3600 seconds. `environment_label` (nil by
default) shows a short badge in the header; nothing is shown without it.
`validation_messages = :model` shows the host model's own validation messages
for fields the person may write, and its base messages; `:generic` shows "is
invalid" for every field, for hosts whose messages could carry values an editor
should not see. `queue_name` must be included in any worker with an explicit
queue list. Configuration and resource definitions
are process-wide, while authority is per request. Use names for reloadable host
classes and do not mutate configuration after boot.

## Mount at a Different Path

```ruby
mount RailsAiAdmin::Engine => "/backoffice", as: :rails_ai_admin
```

Keep exactly one engine mount whose final helper name is `rails_ai_admin`;
request-local log filtering resolves that name. The path can change, but cannot
contain dynamic path parameters, and the mount must accept all HTTP verbs. This
parenthesized spelling is an alternative to the example above, not a second mount:

```ruby
mount(RailsAiAdmin::Engine, at: "/backoffice", as: "rails_ai_admin")
```

Installation inspects the target host's actual loaded RouteSet. A route defined
through `draw :admin`, `self.mount` or another valid Rails spelling is assessed by
its resulting engine endpoint, path parts, verbs and final helper name. It does
not parse source or require literal-only Ruby syntax. A namespace that prefixes
the helper to `staff_rails_ai_admin`, for example, is unsupported even when the
inner declaration says `as: :rails_ai_admin`.

Run the installer inside the target Rails application so that its root and loaded
routes match the destination. Other aliases, prefixed helper names, dynamic
parameters, verb restrictions and multiple admin mounts are rejected before
writing. When no admin mount exists, a different route occupying the
`rails_ai_admin` name is also rejected. The engine does not install login/logout
routes or redirect to a guessed host sign-in page.

## Show the Signed-In User

The header renders the empty partial `rails_ai_admin/shared/_session.html.erb`.
Override it in the host (`app/views/rails_ai_admin/shared/_session.html.erb`) to
show the current user's name and a sign-out button; `main_app` reaches host
routes and the admin `@context` is available. It is the `session_links` entry in
the [Template Catalog]({% link _reference/template-catalog.md %}).

## Connect Sign-In

`config.authentication_path` defaults to nil. Set it to a fixed internal host
path such as `/users/sign_in`. A signed-out person who opens an admin page by a
plain GET is then redirected there with `return_to` set to the requested path
(without its query string, which can hold search text). Your sign-in action must
validate `return_to` as an internal path before redirecting to it. Form
submissions, Turbo Frame requests and form recovery keep the 401 response, so
an open form is never discarded, and the same path is offered as a new-tab
sign-in link for paused generic create/update forms. Include the full host relative-URL-root prefix when used.
Only conservative slash-separated alphanumeric/underscore/hyphen segments are
accepted; query strings, fragments and external URLs are rejected. With nil,
users sign in manually through the host.

[Form Session Recovery]({% link _advanced/form-recovery.md %}) retains input only
in the original open DOM and requires manual Resume plus explicit Save. It does
not provide persistent drafts, login routes or automatic write replay.

## Next Steps

* [Durable Outbox]({% link _advanced/durable-outbox.md %}) configures Work and a fresh job-context resolver.
* [Pundit and Devise]({% link _advanced/pundit-and-devise.md %}) connects explicit policies and host sessions.
* [Host Verification]({% link _advanced/host-verification.md %}) checks your policy boundary.
* [Operations]({% link _core_features/operations.md %}) covers intent expiry and execution-time authorization.
