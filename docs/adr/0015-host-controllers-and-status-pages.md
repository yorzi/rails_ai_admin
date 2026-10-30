# ADR 0015: Host controllers share authority and execution, not the native layout

Status: implemented development contract; Phase 2 and release gates remain open.

`RailsAiAdmin::CustomController` is the public base for ordinary host-owned Rails
controllers, views and partials. It inherits fresh admin Context resolution,
CSRF, private/no-store responses, security headers and action-parameter filtering.
It does not inherit host ApplicationController concerns or select a host layout.
The host chooses its layout and remains responsible for its trusted Ruby code.

Protected entry points are admin_context, admin_access(registered_key),
admin_operation_runner, admin_routes, admin_csp_nonce and admin_status(kind).
None is an additional routable action. Resolving Access grants nothing: a host
action must use current scoped lookup/action grants and project allowed fields.
Writes use the same Runner and explicit route/resource/operation/target binding,
typed input, original intent and human confirmation as native pages. Receipt
authority remains independent of a command's current precondition.

Unqualified route helpers retain the host context. admin_routes is Rails' public
named mounted proxy; it includes the actual mount and SCRIPT_NAME. No private
route proxy or controller _routes override is introduced. Optional host routes
under the engine prefix use Engine.routes.prepend in an initializer before route
drawing, with an absolute host controller path. The existing initial URL logger
filters the engine prefix; URLs outside it remain the host's logging concern.
Layouts loading the prebuilt Turbo bundle supply csp-nonce meta from the public
admin_csp_nonce view helper so its injected progress style obeys the header.

Presentation::Status.fetch accepts only eight known kinds and returns immutable
fixed text: authentication_required 401, forbidden 403, not_found 404, conflict
409, invalid_query/invalid_request 422, unavailable 503 and error 500. Explicit
host page-level forbidden is available; ordinary unknown/forbidden records and
unknown access codes retain anti-enumeration 404. No exception, business value,
request message or redirect URL is a presentation input. Error text cautions that
a prior write may have completed.

admin_status renders but does not halt action execution; callers must return.
HTML/Turbo status responses use a dedicated minimal HTML layout, no JS/resource
menu and turbo-visit-control reload. Only authentication status may offer the
fixed validated internal sign-in path. Non-HTML responses stay plain text. If
status-template rendering fails, fixed plain text preserves the HTTP status and
session marker and clears any false recovery-ready marker. This rescue covers
only rendering; arbitrary action exceptions still reach host error handling.

Two catalog entries, status_layout/status_page at context revision 1, bring the
catalog to 26 paths. Existing context revisions are unchanged. Ordinary host
view precedence and the override generator/doctor metadata contracts apply.

Packaged Host A adds a third distinct domain, Order, alongside Customer and
Host B's UUID Ticket. Its separate host migration adds no Engine migration.
Native Order CRUD exercises exact money/date/false Boolean values, model
validation, readonly state and dependency-authorized computed context. The
host-owned Order workbench shares ReviewOrderOperation with the native member
endpoint. Preview is a non-Turbo Rails form posting to an HTML confirmation;
confirmation submits the bound proposal and redirects 303 on success. A Turbo
form cannot consume an ordinary successful 200 HTML POST response. Chrome found
that fixture mistake; it was corrected rather than attributed to a dependency.

Acceptance verifies workbench preview, native execution and workbench replay
consume one original intent/audit/version transition, with tenant/role denial,
stale version and changed confirmed input rejected. Real development reload
replaces host controller/resource/operation/registry objects; HTTP executes the
new controller and rejects an old operation-version approval without a write.
Chrome verifies preview/confirmation, CSP, the minimal denied edit status and
same-intent native Order recovery preserving decimal/date/false values after
session rotation, followed by explicit Save. A 390px dark workbench was visually
checked. These remain author-controlled local checks, not independent acceptance.

The real unique-index rejection test additionally fixes an own Runner defect:
RecordNotUnique becomes CONFLICT after transaction rollback, leaving the second
intent unconsumed and no duplicate row/success audit. Temporary generator mount
probes now isolate their engine RouteSet after drawing the real host first;
Rails' shared mounted-helper definitions otherwise contaminate randomized tests.
This integration constraint is recorded without claiming multiple-host support
or patching dependency internals.

Resource filters/scopes/navigation configuration, full browser/I18n/accessibility
coverage and the remaining phase/release evidence are still open. The next narrow
AI integration path must reuse this Order operation with a trusted Surface and
released RubyLLM persistence/continuation; none of that is established here.
