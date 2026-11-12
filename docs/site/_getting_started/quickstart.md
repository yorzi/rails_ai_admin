---
layout: default
title: Ten-Minute Quickstart
nav_order: 1
description: Go from a Rails app with sign-in to a working, policy-checked Users admin.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* How to install the engine and keep it closed until you open it.
* How to turn the generated examples into a working context and policy.
* How to list, read and then edit your users through the admin.

This guide starts from an app made with Rails 8's authentication generator, the
shortest path to a signed-in user. Every step below was run against a fresh
`rails new` app. If your app signs in another way, read
[Getting Started]({% link _getting_started/getting-started.md %}) instead; the
policy part is the same.

## 1. Start from an App With Sign-In

Skip the commands you have already run in your own app:

```sh
rails new quick
cd quick
bin/rails generate authentication
bin/rails generate migration AddAdminToUsers admin:boolean
```

Give the new column `null: false, default: false` in its migration. Only users with
`admin` set will reach the admin. Your app also needs a `root` route, because the
authentication generator returns there after sign-in.

## 2. Install the Closed Engine

Add the gem to the Gemfile. There is no published release yet, so use a local
checkout or a built package (see [Getting Started]({% link _getting_started/getting-started.md %})):

```ruby
gem "rails_ai_admin", path: "../rails_ai_admin"
```

Then install it:

```sh
bundle install
bin/rails generate rails_ai_admin:install
bin/rails db:migrate
```

The engine is now mounted at `/admin` and closed. `AdminContext` returns no one,
and `AdminPolicyAdapter` grants nothing. Each generated file also contains a
commented, working example for this kind of app.

## 3. Use the Examples

In `app/rails_ai_admin/admin_context.rb`, delete the closed `resolve` method and
uncomment the example below it. It reads the session cookie that the
authentication generator sets, admits only admins, and uses one fixed tenant
because this app has no accounts:

```ruby
class AdminContext
  SingleTenant = Data.define(:id)
  TENANT = SingleTenant.new(id: "app")

  def resolve(controller)
    session = Session.find_by(id: controller.request.cookie_jar.signed[:session_id])
    user = session&.user
    return unless user&.admin?
    RailsAiAdmin::Context.new(actor: user, tenant: TENANT, security_version: user.updated_at.to_i.to_s)
  end
end
```

Uncomment the example in `app/rails_ai_admin/admin_policy_adapter.rb`. It lets an
admin list and read users, and grants nothing on any other resource. Its search and
sort grants take effect once the field declares `searchable:` and `sortable:`:

```ruby
class AdminPolicyAdapter < RailsAiAdmin::Authorization::Adapter
  def scope(context:, resource:, relation:)
    resource.key == :users ? relation.all : relation.none
  end

  def allowed?(context:, action:, resource:, record: nil)
    resource.key == :users && %i[index show].include?(action)
  end

  def fields(context:, resource:, action:, record: nil)
    return [] unless resource.key == :users
    case action
    when :read then %i[id email_address created_at]
    when :search, :sort then %i[email_address]
    else []
    end
  end
end
```

Each line is a decision about your data. With accounts, return the user's account
as the tenant and scope by it, for example `relation.where(account_id: context.tenant.id)`.

## 4. Generate and Register the Resource

```sh
bin/rails generate rails_ai_admin:resource User --fields email_address created_at
```

This writes `app/rails_ai_admin/user_admin.rb` with `id`, `email_address` and
`created_at` enabled, titled by the email address and `readonly`. The other
suggested columns stay commented, and `password_digest` is never suggested.
Register it, and send signed-out visitors to the sign-in page, in
`config/initializers/rails_ai_admin.rb`:

```ruby
config.resources = ["UserAdmin"]
config.authentication_path = "/session/new"
```

## 5. Check It

```sh
bin/rails rails_ai_admin:doctor
bin/rails test test/rails_ai_admin/access_test.rb
bin/rails server
```

Mark a user as an admin in the console (`User.find_by(email_address: "...").update!(admin: true)`),
sign in, and open `/admin/users`. You should see:

* A signed-out browser visit redirects to `/session/new`.
* A signed-in user without `admin` is sent there too: the example context admits
  only admins. Requests that do not ask for HTML get a 401.
* An admin sees the users list and each user's page, with no password digest.

## 6. Allow Editing (Optional)

Admin forms use optimistic locking, so add `lock_version` first:

```sh
bin/rails generate migration AddLockVersionToUsers lock_version:integer
```

Give it `null: false, default: 0`, run `bin/rails db:migrate`, remove `readonly`
from `UserAdmin`, then grant the action and the field in the policy:

```ruby
resource.key == :users && %i[index show update].include?(action)
# ...
when :write then %i[email_address]
```

An admin can now edit an email address. The save runs through the shared operation
boundary and writes an audit event. Keep a resource `readonly` if its callbacks send
mail or call other services.

## Next Steps

* [Configuration]({% link _getting_started/configuration.md %}) covers other sign-in systems and Pundit.
* [Resources and Fields]({% link _core_features/resources-and-fields.md %}) defines search, sort and filters.
* [Associations]({% link _core_features/associations.md %}) adds `belongs_to` references and `has_many` panels.
