---
layout: default
title: Ten-Minute Quickstart
nav_order: 1
description: Generate an editable admin from an app with Rails authentication or Devise.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* How to connect existing sign-in without writing an authentication adapter.
* How to opt into the trusted-staff policy and generate resources.
* How to review exposure and keep tenant data scoped.

## Prepare Sign-In

Use Ruby 3.3+ and Rails 8.1.4.1+ below 8.2. In a fresh Rails app:

```sh
bin/rails generate authentication
bin/rails generate migration AddAdminToUsers admin:boolean
bin/rails db:migrate
```

Give the admin column `null: false, default: false` before migrating. Add a
`root` route for the authentication generator's sign-in redirect. Create your
business models and migrate them before installing the admin.

Devise apps can keep their existing sign-in setup. The installer uses the `user`
scope when present, otherwise the first mapping. It requires `admin?` to be true,
except for the exact `admin` and `admin_user` scopes, where every active signed-in
account is admitted. Review that choice in the generated `AdminContext`.
Unknown authentication systems receive a closed context to implement yourself.

## Install and Generate

{% if site.docs_unreleased %}
Use this checkout in the host Gemfile; 0.2.0 is not published:

```ruby
gem "rails_ai_admin", path: "../rails_ai_admin"
```
{% else %}
```ruby
gem "rails_ai_admin", "{{ site.version }}"
```
{% endif %}

From an app with migrated models and sign-in, run:

```sh
bundle install
bin/rails generate rails_ai_admin:install --full-access
bin/rails db:migrate
bin/rails generate rails_ai_admin:resource --all
bin/rails rails_ai_admin:doctor
```

The installer mounts `/admin`, connects sign-in, and adds identity and sign-out
controls. The resource generator writes explicit files under `app/rails_ai_admin`
and registers them in the initializer. It generates list columns, search, sort,
filters, supported fields, references and child panels from schema metadata.
Models with `updated_at` or `lock_version` are editable. Others remain readonly.

For selected models, use `rails_ai_admin:resource Article Billing::Invoice`.
Use `--readonly` to disable writes, `--no-register` to leave registration manual,
or `--fields title body` to select fields on a single model. Password digests,
authority flags, encrypted columns and other sensitive names are omitted.
`--all` skips Rails sign-in sessions and existing resources. Names alone cannot
prove that a field's contents are safe: review each generated resource.

## Decide Who Gets Access

Set `admin: true` on your trusted staff account, sign in, and open `/admin`.
The Rails context requires `admin?`; it does not grant access to every user.
The full-access policy grants admitted staff every declared capability across
all rows of each registered model. It supplies no tenant condition or roles.
The assistant remains off and its policy grant stays closed.

For accounts, change the context to return the user's account and narrow the
policy relation, for example:

```ruby
class AdminPolicyAdapter < RailsAiAdmin::Authorization::FullAccessAdapter
  def scope(context:, resource:, relation:)
    relation.where(account_id: context.tenant.id)
  end
end
```

Apply this only to models with that tenant column; define explicit scopes for
other models. Omit `--full-access` during installation to start with a policy
that denies all actions and fields. To opt in later, edit the policy superclass;
rerunning installation preserves existing host files even with `--force`.

## Verify the Host

```sh
bin/rails test test/rails_ai_admin/access_test.rb
bin/rails server -b 127.0.0.1
```

Check an anonymous visit, a signed-in non-admin, and your staff account. Edit a
record and check its history. Keep resources readonly when callbacks have
effects that cannot roll back.

A generated User resource omits the password, and a new user needs one. The
generator therefore turns creating off for that resource and leaves the field
as a comment. To create users in the admin, enable the write-only field and
remove the `disable :create` line in `app/rails_ai_admin/user_admin.rb`:

```ruby
class UserAdmin < RailsAiAdmin::Resource
  # ...
  fields do
    # ...
    password :password
  end
end
```

Admins can then set any user's password, so make that choice on purpose.
Stop the local server when finished.

The repository's `script/packaged_quickstart_smoke.rb` checks fresh Rails
authentication, generated registration, audited create/update, revocation and
installer reruns using the built gem. Your host's roles, callbacks and tenant
boundaries need their own tests.

## Next Steps

* [Configuration]({% link _getting_started/configuration.md %}) covers host authority and Pundit.
* [Resources and Fields]({% link _core_features/resources-and-fields.md %}) defines exposure.
* [Associations]({% link _core_features/associations.md %}) explains reference and child panels.
