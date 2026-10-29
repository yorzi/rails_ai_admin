---
layout: default
title: Pundit and Devise
nav_order: 3
description: Map each admin resource to an explicit Pundit policy and authenticated host context.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* How to select the optional Pundit adapter without model-policy inference.
* How to separate action, field and SQL scope permissions.
* How a Devise host resolves a fresh actor and verified tenant membership.

## Map a Policy to Each Resource

Add Pundit to the host bundle; the adapter accepts version 2.5 through below 3:

```ruby
# Host Gemfile
gem "pundit", ">= 2.5", "< 3"
```

Then select the adapter and an explicit policy class name:

```ruby
# config/initializers/rails_ai_admin.rb
RailsAiAdmin.configure do |config|
  config.context_adapter = "AdminContext"
  config.authorization_adapter = "RailsAiAdmin::Authorization::PunditAdapter"
  config.resources = ["TicketAdmin", "ClosedTicketAdmin"]
end
```

```ruby
# app/rails_ai_admin/ticket_admin.rb
class TicketAdmin < RailsAiAdmin::Resource
  model "SupportTicket"
  key :tickets
  policy "TicketPolicy"
  title :subject
  fields do
    id :id
    text :subject, required: true, nullable: false,
      searchable: :prefix, sortable: true
    enum :state, values: %w[open triaged closed], nullable: false
    integer :priority, sortable: true
    textarea :internal_note
  end
end
```

These are the model/field names in the packaged support host. Its UUID
`SupportTicket` has `tenant_id` and `lock_version`; adapt the policy and schema to
your own domain. The resource's `policy` must be a class-name string, not a cached
class object. The adapter resolves it again for reloadable host code.

A missing policy does not fall back to `SupportTicketPolicy`. Two resources on the
same model must each declare their policy explicitly, so an alias cannot inherit a
wider resource's authority by model inference.

## Use the Complete Context in Policies

The policy receives an admin `Context`, not a bare Devise user. Action predicates
and field grants remain separate:

```ruby
class TicketPolicy
  attr_reader :context, :record

  def initialize(context, record)
    @context, @record = context, record
  end

  def index? = %w[viewer operator admin].include?(context.actor.role)
  def show? = index? && record.tenant_id == context.tenant.id
  def create? = %w[operator admin].include?(context.actor.role) && record.tenant_id == context.tenant.id
  def update? = %w[operator admin].include?(context.actor.role) && show?
  def destroy? = context.actor.role == "admin" && show?

  def readable_fields
    fields = %i[id subject state priority]
    context.actor.role == "viewer" ? fields : fields + [:internal_note]
  end

  def writable_fields = %w[operator admin].include?(context.actor.role) ? %i[subject state priority internal_note] : []
  def searchable_fields = [:subject]
  def sortable_fields = [:priority]

  class Scope
    def initialize(context, relation)
      @context, @relation = context, relation
    end

    def resolve
      if %w[viewer operator admin].include?(@context.actor.role)
        @relation.where(tenant_id: @context.tenant.id)
      else
        @relation.none
      end
    end
  end
end
```

The supported action predicates are `index?`, `show?`, `create?`, `update?` and
`destroy?`. Missing predicates deny the action. Missing `readable_fields`,
`writable_fields`, `searchable_fields` or `sortable_fields` methods grant no fields;
`permitted_attributes` does not implicitly supply these grants. DSL flags and
readonly rules can still narrow the returned lists.

The policy must own its `Scope`, or explicitly inherit it from a parent policy
class. The adapter never accepts an unrelated `Object::Scope`. The Scope receives
`(context, relation)` and must return a complete SQL filter relation of the resource
model. Do not use limit/offset/select/group/having/from shapes; the shared access
layer rejects these rather than widening their membership in later queries.

A readonly alias can define its own narrower scope:

```ruby
class ClosedTicketPolicy < TicketPolicy
  def writable_fields = []

  class Scope < TicketPolicy::Scope
    def resolve = super.where(state: "closed")
  end
end

class ClosedTicketAdmin < RailsAiAdmin::Resource
  model "SupportTicket"
  key :closed_tickets
  policy "ClosedTicketPolicy"
  title :subject
  readonly
  fields do
    id :id
    text :subject, searchable: :prefix
    enum :state, values: %w[open triaged closed]
  end
end
```

Normal Pundit denials return no action permission. Unexpected policy evaluation
errors become a generic `ConfigurationError` without returning the original
exception text or cause. This is a failed configuration/decision, never a
permission grant. Doctor reports mapping metadata only; finding a policy and
Scope does not prove their authorization logic.

## Resolve Devise Sessions Through the Host

The packaged host owns `StaffUser`, Devise sessions and tenant memberships. Its
context adapter authenticates through Warden, then reloads the actor and verifies
the current tenant through membership:

```ruby
class AdminContext
  def resolve(controller)
    authenticated = controller.request.env["warden"]&.authenticate(scope: :staff_user)
    actor = authenticated && StaffUser.find_by(id: authenticated.id)
    return unless actor

    selected = controller.session[:active_tenant_id]
    tenant = selected ? actor.tenants.find_by(id: selected) : actor.tenants.order(:id).first
    return unless tenant

    RailsAiAdmin::Context.new(
      actor: actor, tenant: tenant,
      security_version: actor.security_version.to_s
    )
  end
end
```

The selected tenant comes from the host session, and membership is checked again.
An arbitrary submitted tenant ID is not authority. Loading the actor afresh keeps
role/version decisions from relying on a cached Warden object. Change the host's
security version when authority changes. Tenant identity is also bound to every
intent, so a form from one tenant cannot be used after switching to another.

Devise login, logout and timeout behavior remains host-owned. A missing context
normally gives the engine's generic 401; Warden may invoke the host's sign-in
failure response, including a redirect on session timeout. The engine does not
create accounts, roles or login/logout routes.

## Keep Product SDK Objects Separate

The support fixture already has a product `ProductChat`/`ProductMessage` and a
host-owned `rails_tool_views` Surface. Conventional admin CRUD and development
reload preserve those product configurations and ownership boundaries. Product
Surface references use a separate namespace from `raa:` admin actor/tenant refs.

These checks use synthetic data, no real provider keys and no provider calls.
They do not establish full admin Chat, Surface dispatch or durable continuation
coexistence, which remain unimplemented. The author-controlled packaged hosts
also do not replace independent usability/security review or close release Gates
A through E.

## Next Steps

* [Host Verification]({% link _advanced/host-verification.md %}) runs packaged-consumer and recovery probes.
* [Operations]({% link _core_features/operations.md %}) explains policy-fingerprint changes and intent invalidation.
* [Configuration]({% link _getting_started/configuration.md %}) describes the custom-adapter alternative.
