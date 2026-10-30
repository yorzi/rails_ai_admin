# ADR 0013: Recover open generic forms by renewing their original intent

Status: implemented development contract; Phase 2 and release gates remain open.

Generic native create/update forms preserve their open DOM only after an
Engine-marked authentication 401 or CSRF 422 response. Ordinary validation keeps
its normal rendering. The client verifies the exact same-origin submission URL,
response marker and absence of a redirect before preventing Turbo replacement.
Save stays disabled until the original request has finished and explicit recovery
succeeds. Network errors and ambiguous outcomes are not classified as known
unexecuted authentication failures.

The host owns login. An optional frozen `authentication_path` accepts only a fixed
origin-relative path with conservative segments and no query/fragment. It opens a
separate tab with noopener/noreferrer. A configured relative URL root must be part
of that host path. Without configuration, the notice gives manual sign-in
instructions. No automatic login redirect discards the original DOM.

After sign-in, explicit Resume performs a same-origin, no-store, redirect-rejecting
GET to `/:resource/forms/recover`, relative to the Engine mount. The original UUID
is supplied only in `X-RailsAiAdmin-Recovery-Intent`; query/body references are not
accepted as its binding. The request sends no draft input. This custom unguessable
header, current authentication, same-owner checks and the default absence of
credentialed cross-origin access prevent a simple cross-site GET from renewing a
form. Hosts must not expose authenticated Engine routes through permissive CORS.
Responses are private/no-store and vary by Cookie and the intent header.

`Runner#resume_form` locks the existing run. It accepts only the same actor/tenant,
UI root, proposed, unbound and unapproved built-in create/update intent. Child,
selection, custom operation, delete, running and completed intents are rejected.
A fresh Context, resource fingerprint, action/scope/write fields and original
record version are rechecked. Recovery is bounded to one hour from `created_at`;
expiry is the lesser of current configured TTL and that absolute deadline.
The same intent gets the fresh security epoch and bounded expiry. No input,
replacement intent, approval, business write or business audit is created.
Host ERB renders after the transaction/row lock has ended.

Reusing the original intent preserves consumption/replay identity across repeated
Resume attempts and cloned tabs. If a save wins first, recovery rejects the
consumed run. If recovery wins first, a later explicit Save still passes through
the shared Runner's current context, fields, record version and atomic receipt.
Recovery cannot create a second intent after an uncertain prior create.

The response supplies a fresh form/CSRF token and a ready marker only after
successful rendering. The client checks that marker, HTML type, original hidden
intent, action/method and time zone before replacement. It snapshots the latest
open DOM only after the response arrives, then synchronously copies supported
scalar controls under the fresh editable-field allowlist. Old security fields,
readonly/disabled/file/hidden inputs and unavailable select options are not
copied. Checkbox fallback hidden values remain the fresh server values. New
readonly outputs are current authorized server data. Fresh global CSRF metadata
is updated when present. Restored input is dirty and still needs explicit Save.
A disconnected form aborts its request and cannot be replaced later.

The transient snapshot is bounded to 128 names/1 MiB; fresh HTML is bounded to
2 MiB. The engine writes no draft to localStorage, sessionStorage, IndexedDB,
cookies or a server draft table. Page refresh/navigation/close can lose input;
no-JavaScript forms still work but lack this recovery enhancement. Custom
operation/delete recovery and persistent draft workflows remain open.

Contracts/native requests cover owner/tenant/action/scope/version/age/contract
rejection, input-bound and child/delete restrictions, current field narrowing,
render errors and safe response markers. Both packaged hosts verify session loss
or actual Devise timeout, fresh authentication, the same intent and one explicit
save. Chrome checks verify session rotation/CSRF pause, fresh-token save, a held
recovery response while the user continues typing, and a competing-tab version
change rejected with 409 while retaining the stale input. Expected 422/409 network
console entries are failure-path evidence; no application JS/CSP error was seen.
These checks do not certify every browser or assistive technology.

The catalog adds `form_recovery` (revision 1); new/edit/shared form revisions
advance to 3. This advances CRUD-022 and RAA-0212 without closing the remaining
return-location, status/controller extension and three-domain-resource gates.
