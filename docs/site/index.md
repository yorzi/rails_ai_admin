---
layout: home
title: Rails AI Admin
description: Build authorized admin pages with explicit resources and atomic operations.
permalink: /
hero:
  name: Rails AI Admin
  text: A self-hosted admin for Rails
  tagline: Manage records with default-deny policies and one audited write path. Enable AI when your team needs it.
  actions:
    - theme: brand
      text: Get started
      link: /quickstart/
    - theme: alt
      text: Try the demo
      link: /demo/
features:
  - title: An admin for your Rails app
    details: Manage records with forms, associations, search, dashboards, CSV import and export, and an audit trail.
    link: /resources-and-fields/
    link_text: Configure resources
  - title: Your users and permissions
    details: Connect your existing authentication and policies. Control which records, fields, and actions each administrator can access.
    link: /configuration/
    link_text: Connect your app
  - title: AI with human approval
    details: Ask questions about authorized records. Review proposed changes in chat before confirming them.
    link: /admin-assistant/
    link_text: Set up the assistant

---

## Install Rails AI Admin

{% if site.docs_unreleased %}
Build a local package from this checkout:

```sh
bundle install
bundle exec rake test
bundle exec rake build
```

The package is `pkg/rails_ai_admin-{{ site.version }}.gem`.
{% else %}
Add the Public Preview to the host app's Gemfile:

```ruby
gem "rails_ai_admin", "{{ site.version }}"
```

Run `bundle install` in your host app.
{% endif %}

The [ten-minute quickstart]({% link _getting_started/quickstart.md %}) takes an app with
Rails 8 sign-in to a working Users admin; the
[installation guide]({% link _getting_started/getting-started.md %}) connects other
hosts. It remains closed until you supply authentication and policies.

## A First Look

```ruby
class CustomerAdmin < RailsAiAdmin::Resource
  model "Customer"
  key :customers
  title :name
  fields do
    id :id
    text :name, nullable: false, required: true
  end
end
```

The declaration narrows exposure; it grants no permission. The host owns the model,
its tenant scope and every action/field decision. Writes detect concurrent edits
through `lock_version` or `updated_at` and share the domain's connection pool.

## See It Running

`bin/demo --assistant` serves a seeded admin on `127.0.0.1` with every feature
turned on: uploads, rich text, imports, history, charts, search, and AI chat and
MCP against an offline fake model. Open `http://127.0.0.1:3917/login` and click
**Sign in as Admin**. See
[Try the Demo]({% link _getting_started/demo.md %}).

## Choose Your Next Step

* [Configure resources and fields]({% link _core_features/resources-and-fields.md %}) to build forms and record lists.
* [Set up the assistant]({% link _advanced/admin-assistant.md %}) to connect RubyLLM and your model provider.
* [Add review cards]({% link _advanced/review-surfaces.md %}) to confirm changes inside chat with rails_tool_views.
* [Connect an MCP client]({% link _advanced/mcp-server.md %}) to use the same permission-checked tools from an external agent.
* [Verify your host integration]({% link _advanced/host-verification.md %}) before enabling access for your team.

## Version {{ site.version }}

This release is a Public Preview. Read [what is available]({% link _getting_started/whats-new-in-0-1.md %})
and the [current limitations]({% link _reference/development-status.md %}) before adopting it.
