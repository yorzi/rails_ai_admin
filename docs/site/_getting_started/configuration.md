---
layout: default
title: Configuration
nav_order: 2
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

## Configure Before Boot

```ruby
RailsAiAdmin.configure do |config|
  config.context_adapter = "AdminContext"
  config.authorization_adapter = "AdminPolicyAdapter"
  config.resources = ["CustomerAdmin"]
  config.title = "Operations"
  config.intent_ttl = 15.minutes
end
```

`intent_ttl` accepts 60 through 3600 seconds. Configuration and resource definitions
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

## Next Steps

* [Durable Outbox]({% link _advanced/durable-outbox.md %}) configures Work and a fresh job-context resolver.
* [Pundit and Devise]({% link _advanced/pundit-and-devise.md %}) connects explicit policies and host sessions.
* [Host Verification]({% link _advanced/host-verification.md %}) checks your policy boundary.
* [Operations]({% link _core_features/operations.md %}) covers intent expiry and execution-time authorization.
