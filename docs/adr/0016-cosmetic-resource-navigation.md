# ADR 0016: Resource menus are cosmetic projections of current index grants

Status: implemented development contract; Phase 2 and release gates remain open.

`Resource.navigation(group:, label:, icon:, order:, hidden:)` declares static
presentation metadata only. `navigation false` is shorthand for hidden. The
settings are an immutable `Navigation::Settings` value: group/label are plain
UTF-8 (or ASCII normalized to UTF-8) text of 1..80 characters without C0/DEL
controls or all-whitespace values; order is an Integer from -1000 to 1000; hidden
is Boolean; icon is nil or one fixed String name. Unknown options, Procs, URL
targets, Symbol icons and arbitrary SVG/HTML are configuration errors. Subclasses
start with their own default settings rather than inheriting a parent's menu.

The fallback `Resource.label` uses the same caption bounds. Registration rejects an
unusable fallback for a visible entry, so a bad label fails boot instead of making
every layout render unavailable. Menu building still rechecks the caption because
a label can change after registration in tests or reload.

`Navigation::Menu.build(context:, resources:, current_key:)` requires a current
Context and authorizes `:index` for each resource before reading its metadata.
Denied resources leave no label, icon or empty group. Hidden entries are removed
after that check. Entries sort by order then registry position; groups appear in
first-appearance order of that sorted list with their entries contiguous. Group
and Entry snapshots are frozen and carry only key/label/icon/current. No record,
count, scope or policy object is retained, and the framework performs no domain
query. Host policies may query and remain host-owned code.

The controller memoizes the snapshot for one request only. The next request
rebuilds with fresh grants; nothing is stored in session or across requests.
Current marking compares the resolved resource key, not URL text. Links use the
named resource index route so mount and SCRIPT_NAME are preserved. The resource
link uses `aria-current="location"`; Overview uses `"page"` on the dashboard.

Hiding is not authorization. A hidden resource's direct routes keep the same
current index/show/write decisions, and showing a resource grants nothing.
Navigation settings are excluded from operation-intent and Selection identity, so
renaming, reordering or hiding a menu never invalidates an approval or manifest.

Icons are original project-owned outline paths rendered with fixed attributes,
decorative `aria-hidden`/`focusable=false`, and the label as accessible text. The
accepted names and the glyph table are tested for parity.

Template compatibility: a new `resource_navigation` partial (revision 1, local
`groups`) brings the catalog to 27 entries. The layout advances to revision 3
and the dashboard to 2 because both now consume `resource_navigation`. Legacy
`visible_resources` still returns every index-authorized resource, including
menu-hidden ones, so existing overrides keep their previous behavior until they
adopt the new helper deliberately.

Contract/request tests cover bounds, immutability, denied-metadata laziness,
ordering/grouping, escaping, mount prefixes, fresh grants, hidden direct access,
boot-time fallback-label rejection and unchanged intent/Selection identity. Host A
declares grouped Customer/Order icons and a hidden readonly directory alias; its
real reload probe renames the Order group/label and observes the new menu. Host B
renders Support labels/icons from Pundit grants and removes them for a suspended
role, and renders a host `resource_navigation` override on both asset pipelines.
No Chrome or screen-reader check was made for this milestone.

This advances RAA-0201 (navigation configuration) and RAA-0209. Filters, named
scopes, record-count badges, dynamic menus, custom destinations and the full
browser/accessibility matrix remain open.
