# ADR 0011: Individual host overrides carry source and context metadata

Status: implemented development contract; the full Phase 2 and release gates
remain open.

Conventional presentation has a fixed catalog of 23 current templates: layout,
resource landing/list/show/new/edit/shared form/delete/errors, field display/input
and row partials, member and collection operation wrappers, fixed selection and job pages.
Each entry names its path, explicit assigns/locals and a context revision. Surface
wrappers are unavailable until their actual integration exists; plain controller
error responses are not catalogued templates.

`rails_ai_admin:override KEY` copies exactly one entry to standard host `app/views`.
`--list` shows installed keys and contracts. Existing host files survive normal,
forced and revoke invocations. The final create is exclusive so a file appearing
after the precheck cannot be overwritten. Writes use binary mode to preserve
Unicode source bytes. Known parent/leaf symlinks, including dangling links, and
directory conflicts are rejected; an explicitly selected symlink host root is
resolved. These checks are not a filesystem or trusted-Ruby sandbox.

A first-line ERB comment stores format, key, gem version, source SHA-256 and
context revision. It is deterministic and does not render into the response.
There is no separate host manifest and no automatic merge/acknowledgement. Host
body edits are expected. Source digest and context revision are independent;
controller/helper contract changes require a deliberate catalog revision bump.
Version alone does not mark an override stale if source/context still match.

Doctor reads only bounded first-line metadata and never evaluates host ERB.
It inspects standard engine view namespaces, with 256-template/1024-entry bounds
and a 1024-byte header limit. Truncated inspection is explicitly incomplete.
Stale, manual and uncatalogued overrides require review; malformed metadata and
unsafe paths are errors. `CURRENT` proves source/context metadata agreement only,
not correct authorization, CSRF, escaping, usability or host-body compatibility.
Custom/dynamic view paths remain host acceptance responsibilities.

New and edit have independent wrappers for initial GET, validation and conflict
rerenders. They explicitly render the existing full shared form with layout false;
the outer layout, one form, CSRF/intent fields and dirty-form bindings remain.
Default field index/show are now real partials. Registered type-specific partials
keep precedence over global defaults. Templates receive trusted Rails context;
content must come from authorized projections, not unrestricted record getters.

Contract/native tests cover preservation, a deterministic creation race, Unicode,
header validation, source/context drift, path bounds, actual rendering and form
failure paths. Packaged Host A render notifications proved all 23 standard-path
host overrides were used by HTTP requests. Host B verified its own subset on both
pipelines plus live stale metadata and actual development template reload. The
fixtures remove their temporary overrides after verification. Installer defaults
never copy the catalog tree into a host.

This advances RAA-0209/0211 and the generator/doctor upgrade contract. It does not
complete status/controller escape hatches, session
recovery, three-domain-resource Phase 2 acceptance or future Surface wrappers.

ADR 0012 adds authorized grouped form plans and advances the affected form context
revisions to 2; inspect the installed catalog for each entry’s current revision.
