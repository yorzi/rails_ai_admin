---
layout: default
title: Form Session Recovery
nav_order: 6
description: Reauthenticate and manually resume an unchanged generic form while its unsaved input remains in the open tab.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* How native create/update forms pause after a marked authentication or CSRF failure.
* How to configure the host sign-in link and resume manually.
* Which intent, identity and version checks permit recovery.
* Why recovery neither saves a draft nor replays a write.

## Configure the Host Sign-In Path

The host still owns authentication. To show a fixed sign-in link in the recovery
notice, configure its actual internal route:

```ruby
RailsAiAdmin.configure do |config|
  config.authentication_path = "/users/sign_in"
end
```

The default nil gives manual instructions to sign in through the host in another
tab. The engine supplies no login route. The configured path must be origin-relative
and contain only conservative slash-separated alphanumeric/underscore/hyphen
segments, without query, fragment, scheme or external host. If the host uses a
relative URL root, include the full host prefix, such as
`/support/users/sign_in`; the engine does not prepend it for this setting.
The link opens another tab so the original form DOM can remain open.

## Resume Explicitly After Authentication

Native generic create/update forms include the `raa-form-recovery` controller.
For their Turbo submission, only an engine-marked 401 authentication failure or
422 CSRF failure pauses the existing form. The response must carry
`X-RailsAiAdmin-Form-Recovery: session`, match the original same-origin submission
URL and have no redirect. Ordinary validation 422 responses keep their normal
rendering behavior; an arbitrary host error page is not treated as recovery.

The paused form keeps its current controls in the open DOM and disables Save.
Sign in as the original user/tenant in another tab, return and press **Resume
after signing in**. The engine fetches a fresh authorized form and restores only
currently editable permitted controls. It obtains a new CSRF token from that HTML,
then asks you to review and **Save explicitly**. It never automatically repeats
the failed request or executes the recovered intent.

The recovery request, relative to the engine mount, is:

| Request | Binding |
| --- | --- |
| `GET /:resource/forms/recover` | `X-RailsAiAdmin-Recovery-Intent` header containing the form's `intent_ref` value |

A native form page writes nothing: its `intent_ref` is a signed form reference
that becomes an intent on the first submit (ADR 0025). Recovery of a form that was
never submitted materializes that same intent, then applies the checks below; a
submitted form's intent already exists. The reference is not placed in a query
string or form URL. The GET carries no draft
input or proposed business values; the host resolves the current authenticated
Context normally. The response is private/no-store and varies by Cookie and the
recovery-intent and return-state headers. A successful HTML response carries
`X-RailsAiAdmin-Form-Recovery: ready` only after successful form rendering.
Unsuccessful or render-error responses are not marked ready. A success response
alone without that marker is not sufficient for the client to replace its form.

List settings use a separate `X-RailsAiAdmin-Return-State` header containing the
server's ASCII Base64URL-encoded UTF-8 JSON hint. It is not draft input, a URL or
authority. Invalid state is discarded and current search/sort grants are checked;
the form action/recovery URL remain queryless. A refreshed-form discard flag
keeps the changed-list-settings notice visible after in-tab recovery. See
[List Navigation]({% link _core_features/list-navigation.md %}) for bounds and
normalized return paths.

## Reopen Only an Eligible Original Intent

The server locks and checks the existing intent. It must be a root, proposed,
unbound, unapproved UI intent for built-in create/update on the same resource.
Child intents, selections, custom operations, delete and completed/consumed
requests cannot use this recovery path. The original actor and tenant must match
the fresh authenticated Context. A different signed-in identity cannot inherit
the retained input.

The resource/operation schema fingerprint must still match, the target must remain
in current scope, its action/current writable-field grants must permit the form
and an update's expected `lock_version` must be unchanged. Recovery has an absolute
one-hour window from the original intent's `created_at`, not an indefinitely
extendable expiry. A stale target, changed contract, revoked action or completed
request requires a fresh form rather than automatic recovery/replay.

After those checks, recovery renews the **same intent's** security version from
the fresh Context and its expiry to the earlier of current intent TTL or the
original one-hour deadline. It creates no replacement intent, grants no approval,
executes no domain write and persists no draft. It can renew an otherwise expired
form TTL only within that absolute window. Normal Runner authorization,
confirmation, version and input checks still run on a later explicit Save.

Trusted host code can use the same server API for an already issued eligible
intent and freshly authenticated context:

```ruby
form_session = RailsAiAdmin::Operations::Runner.new.resume_form(
  context: context, resource: CustomerAdmin, intent_ref: intent.id
)
```

The `Operations::Runner::FormSession` contains the same `intent` and freshly
resolved `record` for trusted form rendering. It is not a client receipt or an
unrestricted projection. Denied/ineligible recovery raises AccessDenied with a
generic native response; configuration errors remain configuration failures.

## Restore Only Current Editable Input

The refreshed form rebuilds current presentation masks, editable fields and
readonly context. The client verifies intent, endpoint, method and time-zone
bindings before transfer. Removed or newly readonly/disabled fields are not
restored. A changed select value is transferred only if a current enabled option
permits it. Hidden/file/submit controls are not treated as recoverable business
input; readonly output uses current server-authorized values, not the old DOM.
The refreshed form retains fresh hidden security fields rather than copying them
from the expired form.

The client snapshots the still-open DOM after fresh HTML and form bindings have
been validated, immediately before synchronous transfer/replacement. Edits made
while the Resume fetch waits are therefore included. Disconnecting the old form
aborts its fetch and prevents later replacement of a departed page.

The in-memory snapshot is bounded to 128 scalar field names and 1 MiB, and the
fresh HTML response to 2 MiB. Controls must use the normal `record[field_name]`
naming and current field contract. Custom templates/field partials must retain
the recovery controller/data values, notice/message/resume targets, Turbo events,
CSRF/intent fields and dirty-form behavior. See
[Template Overrides]({% link _advanced/template-overrides.md %}) before replacing
a form wrapper. After restoration, the form remains dirty until a deliberate
successful save or navigation.

If recovery is rejected, the open tab retains its current DOM input and offers
manual retry. Changed identity, target, schema, time zone or completed requests
can require a fresh form. Field-grant narrowing may instead restore only the
still-editable subset, with a notice that some input was dropped. Do not create
or submit a replacement business intent assuming an earlier ambiguous write
never committed; recovery does not replay completed work.

## Keep the Storage Boundary Clear

This is memory in the **currently open page**, not persistent session drafts.
The engine adds no localStorage/sessionStorage/IndexedDB draft or server draft
record. Refreshing/navigating/closing the page can lose input. Without JavaScript,
ordinary HTML forms still work, but this authentication-failure preservation
workflow is unavailable; sign in and open a fresh form manually.

Only generic native create/update is covered. Custom-operation/delete forms,
persistent drafts and broader workflows remain planned. No full release Gate is
closed by this limited recovery behavior.

## Next Steps

* [Configuration]({% link _getting_started/configuration.md %}) establishes the fresh host identity used for recovery.
* [Resources and Fields]({% link _core_features/resources-and-fields.md %}) explains masks, readonly values and write-only prefills.
* [Operations]({% link _core_features/operations.md %}) explains intent confirmation, replay and post-commit results.
