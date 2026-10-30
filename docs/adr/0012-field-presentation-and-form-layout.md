# ADR 0012: View grants precede projections and forms retain scalar snapshots

Status: implemented development contract; Phase 2 and release gates remain open.

Resource fields declare `index`/`show` output flags and create/edit lifecycle
visibility. `hidden` excludes a resource field from reads, writes, queries and
computed dependencies. These flags narrow existing host grants. The optional
public adapter `presentation_fields(context:, resource:, view:, record: nil)`
returns nil for no additional restriction, or an array of field names. Pundit
policies may implement `presentation_fields(view)`. Unsupported shapes, private
hooks, exceptions and ordinary Active Record writes fail closed. Trusted Ruby
hooks are not a sandbox.

A projection first intersects declared fields, current read grants and the view
permission mask, then closes the recursive dependency graph, and finally selects
static output visibility. An index-hidden scalar may feed an explicitly authorized
summary, but its raw value never enters the rendered values map. A denied dependency
suppresses the summary before getters run. Generic `view: nil` projections retain
the read API; presentation output flags alone are not confidentiality policy.
The public scalar reader enforces the same current resource identity, show/read/
view grants and output visibility. Internal dependency reads use the guarded
physical attribute reader after graph authorization.

Generic writes automatically resolve the create/edit permission mask through the
shared Runner. Create checks again after assignment. Existing intents are bound
to field contracts, so metadata changes invalidate stale forms. A hidden field or
readonly/virtual field never becomes generic input. Custom Operation inputs keep
their own schema and independent permission contract.

Forms infer groups from the currently permitted entries' field `tab` and `panel`
labels. Missing tab labels join Details when another tab is named. Empty denied
groups disappear. Help text is plain bounded text (500 characters); group labels
are bounded to 80 characters. Plans hold at most 128 fields, eight tabs and 16
panels per tab, with 256 KiB per scalar and 1 MiB combined value bounds.
They retain no record/query or unlisted values. This is a layout snapshot, not
session persistence.

`@form_fields` and `@form_values` remain writable-only. `@form_plan` adds entries
with an editable flag and a scalar snapshot. Authorized readonly/virtual fields
may opt into create/edit display; virtual defaults stay false. Readonly context
requires show, read and view grants. Writable fields without read grants render
blank on initial GET; failed submitted values may redisplay only under fresh
write grants. Readonly values always come from fresh readable projection.

The server renders all sections visible and anchor navigation usable without
JavaScript. Stimulus adds tab roles, roving focus, arrow/Home/End navigation and
hidden inactive panels without disabling controls. Capturing native invalid events
reveals the first invalid control's section before browser focus; multiple invalid
controls do not switch to the last error. A server failure selects the first error
section and focuses an error summary; links reveal and focus current editable
inputs. Help/error IDs append `--help`/`--error`, disjoint from legal field names.

The override catalog adds `field_row`; new/edit/shared form, error and grouped
input context revisions advance to 2. Optional plan/builder locals preserve
custom Operation forms. Registered field-specific input partials retain precedence.

Contract, native request, packaged host and Chrome spot checks cover these
contracts. Browser checks exercised hidden-input native validation, keyboard tabs,
FormData, server 422 input retention/summary navigation and a 390px dark layout.
A no-JavaScript document was checked as server markup; no assistive-technology or
cross-browser certification is claimed. Session timeout/draft recovery, controller/
status extension points and three-domain-resource acceptance remain open.

ADR 0013 supplies bounded generic open-tab session recovery without a persistent
draft store. New/edit/shared form contexts now use revision 3; inspect the current
catalog rather than treating this earlier milestone's revisions as permanent.
