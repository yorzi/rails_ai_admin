---
layout: default
title: MCP Server
nav_order: 11
description: Let outside AI agents such as Claude Code or Cursor read the admin and propose reviewed changes, through the same grants as admin Chat.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* How to turn on the Model Context Protocol endpoint and issue tokens.
* How to connect Claude Code, Cursor or another MCP client.
* What an agent can read and how its proposed changes are confirmed.
* How tokens fail closed.

## Turn It On

The MCP server builds on [Admin Assistant]({% link _advanced/admin-assistant.md %}):
it needs the assistant tables, ruby_llm and the context adapter's `resolve_job`.
The agent brings its own model, so no provider call is made by the admin.

```ruby
RailsAiAdmin.configure do |config|
  config.assistant = true          # and the rest of the assistant settings
  config.surfaces = true           # lets agents propose reviewed changes
  config.mcp = true
end
```

Run `bin/rails generate rails_ai_admin:assistant` and `bin/rails db:migrate` to
add the `add_streaming_and_access_tokens_to_rails_ai_admin_assistant` migration.
The endpoint is `POST <admin>/mcp`, for example
`https://example.com/admin/mcp`. Serve it over HTTPS only.

## Issue a Token

People who may use admin Chat see **MCP access** in the menu. There they name a
token ("Claude Code on my laptop"), choose 30 or 90 days, and copy it. The token
is shown once; the admin stores only its SHA-256 digest. A person keeps at most
ten active tokens and can revoke any of them.

A token belongs to its owner, tenant and the owner's `security_version`. On
every request the endpoint asks your context adapter's `resolve_job` for that
owner again, so a disabled user, a changed role or a bumped security version
retires the token at once, exactly as it closes their chats.

## Connect a Client

Claude Code:

```sh
claude mcp add --transport http rails-admin https://example.com/admin/mcp \
  --header "Authorization: Bearer raa_mcp_…"
```

Cursor (`.cursor/mcp.json`) and other clients that take a URL and headers:

```json
{
  "mcpServers": {
    "rails-admin": {
      "url": "https://example.com/admin/mcp",
      "headers": { "Authorization": "Bearer raa_mcp_…" }
    }
  }
}
```

The server speaks MCP's Streamable HTTP transport with JSON responses
(protocol versions 2025-06-18, 2025-03-26 and 2024-11-05): `initialize`,
`ping`, `tools/list` and `tools/call`. It keeps no session and opens no
server-sent event stream; `GET` and `DELETE` return 405.

## Tools

Agents get the same tools as admin Chat, bound to the token owner:
`list_resources`, `describe_resource`, `search_records`, `count_records`,
`get_record`, `record_history`, and, with `config.surfaces`, `propose_change`
and `propose_operation`. Each call checks the resource's `assistant?` grant and
the owner's current index, show, field, history and operation grants, as the
pages do. Results are the same bounded, typed JSON; passwords and unreadable
fields never appear.

Agents cannot change data. `propose_change` and `propose_operation` save an
unconfirmed intent and return `review_url`. The owner opens that link while
signed in to the admin, sees the review with before → after values, and only
their **Confirm and execute** writes it, through the Operation Runner with a
version check and an audit event. Give the link to the person, or ask the agent
to show it to you.

## Security Notes

* The endpoint reads no cookie or session, so cross-site requests from a browser
  carry no authority; it also refuses a request whose `Origin` header names
  another host (DNS rebinding).
* Unknown, malformed, revoked or expired tokens get `401` with
  `WWW-Authenticate: Bearer`. Bodies over 64 KB and JSON-RPC batches are refused.
* Reads are not audited; confirmed writes are, like every write. Tokens record
  when they were last used.
* `bin/rails rails_ai_admin:doctor` reports the endpoint and the number of
  active tokens. Rate limiting is left to your proxy or Rack middleware.
