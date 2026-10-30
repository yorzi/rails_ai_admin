---
layout: default
title: Resource Navigation
nav_order: 8
description: Group and label currently authorized resources in the sidebar and Overview without changing direct access.
---

# {{ page.title }}

{{ page.description }}
{: .fs-6 .fw-300 }

After reading this guide, you will know:

* How to declare resource groups, labels, icons and ordering.
* How sidebar visibility stays separate from current authorization.
* How the request builds immutable menu snapshots without record counts.
* How to preserve menu behavior in host template overrides.

## Declare Static Resource Metadata

For host Customer and Order models, add navigation metadata to their reviewed
resource declarations:

```ruby
class CustomerAdmin < RailsAiAdmin::Resource
  model "Customer"
  key :customers
  title :name
  navigation group: "People", label: "Customers", icon: "users", order: 0
  fields do
    id :id
    text :name
  end
end

class OrderAdmin < RailsAiAdmin::Resource
  model "Order"
  key :orders
  title :number
  navigation group: "Commerce", icon: "shopping-bag", order: 10
  fields do
    id :id
    text :number
  end
end
```

The complete declaration is `navigation(group: nil, label: nil, icon: nil,
order: 0, hidden: false)`. Nil group gives an unlabelled group; nil label uses
Resource.label. Registry position breaks ties in entry order. This declaration controls
presentation, not action, scope, field or query permission.

Group/label are optional nonblank plain UTF-8 text of 1..80 characters without
C0/DEL controls. ASCII text is accepted and normalized to UTF-8. Metadata and the
fallback Resource.label use the same bounded plain-text copying; HTML-safe status
is stripped and normal rendering escapes the text. Registration rejects a visible
resource whose fallback Resource.label falls outside these bounds, so the error
appears at boot rather than on every admin page. Order is an Integer from
-1000 through 1000. Unknown options, dynamic Procs and URL-target configuration
are rejected; the destination always remains the named resource index route.

Icons are optional **String** names from this fixed set:

| Name | Project glyph |
| --- | --- |
| `users` | People |
| `shopping-bag` | Commerce |
| `life-buoy` | Support |
| `document` | Document |
| `grid` | Grid |

These are original project-owned SVG paths with fixed attributes, not arbitrary
SVG/HTML, image URLs or a third-party icon registry. They are decorative;
accessible link text remains the label. Unknown names or Symbol icon values
fail configuration.

## Hide a Menu Item While Keeping Authorization Explicit

A registered alias can be absent from the default sidebar and Overview:

```ruby
class CustomerDirectoryAdmin < RailsAiAdmin::Resource
  model "Customer"
  key :directory
  title :name
  readonly
  navigation false
  fields do
    id :id
    text :name
  end
end
```

`navigation false` is the hidden-menu shorthand; `navigation hidden: true` also
hides both default entry points. The direct route remains subject to the same
current policy. Here readonly separately denies writes. Hidden navigation grants
no access and does not revoke an existing direct index/show grant. Field-level
hidden remains its separate resource-exposure boundary.

The menu checks current index authorization before reading an entry's metadata.
Denied resources contribute no label, icon or empty group. Metadata is static
configuration; do not use a dynamic label to make an authorization decision.
Each direct page and business operation must still enforce its own current grants.
Cosmetic navigation settings are excluded from operation-intent and Selection
fingerprints, so renaming/reordering/hiding a menu is not approval invalidation.

## Build the Current Request's Menu

With the host's existing fresh Context and index grants, register the resources:

```ruby
RailsAiAdmin.configure do |config|
  config.resources = ["CustomerAdmin", "OrderAdmin", "CustomerDirectoryAdmin"]
end
```

The public scalar builder uses current authorization:

```ruby
groups = RailsAiAdmin::Navigation::Menu.build(
  context: context,
  resources: RailsAiAdmin.registry.resources,
  current_key: CustomerAdmin.key
)
group_labels = groups.map(&:label) # => ["People", "Commerce"]
```

The example assumes current index grants for Customers/Orders. Menu.build first
sorts visible authorized entries by order, then registry position to break ties.
Groups follow their first appearance in that sorted list, and each group's
entries stay contiguous in their own sorted order. This grouping rule does not
promise a flat global order across interleaved groups.

Groups/entries and copied caption values are immutable. A Group has label/entries;
an Entry has only key, label, icon and current. It carries no record, count, scope,
policy or stored authorization decision. The framework performs no domain record
or count query to build the menu; a host's index policy may itself query and remains
host-owned code.

The `resource_navigation` view helper memoizes this snapshot only for the current
request. The next authenticated request builds with fresh grants; no menu snapshot
is persisted across sessions. Current marking compares the actual resolved
resource key with the current key, not URL fragments. Named route helpers retain
the real mount and SCRIPT_NAME prefix. Global menu links start a fresh list;
[List Navigation]({% link _core_features/list-navigation.md %}) separately carries
per-flow search/sort/page hints.

## Preserve the Public Template Contract

The default layout renders `rails_ai_admin/shared/_navigation.html.erb` with the
`groups` local. Its catalog key is `resource_navigation`, contract revision 1.
The layout is revision 3 and Overview/dashboard revision 2. Overrides should use
resource_navigation and the provided snapshots, preserve group headings and
current-link accessibility attributes, and use only named resource paths.
`navigation_icon(name)` renders the fixed glyphs; keep labels escaped normally.

The legacy `visible_resources` helper remains compatible: it returns **all**
index-authorized resources, including those hidden from the new menu. It does not
apply these cosmetic settings. Host overrides using that helper must deliberately
adopt resource_navigation when they want grouped/default-hidden behavior. Neither
helper grants a later page or operation authority.

The author-controlled native-session host declares People/Customers and
Commerce/Orders icons plus a hidden readonly directory alias. The Devise/Pundit
host declares Support queue and Closed archive labels/icons under Support, still
subject to fresh mapped-policy index grants. Both packaged hosts verify these
menus, Host A's real source reload renders a renamed Order group/label, and Host
B renders a host resource_navigation override on both asset pipelines. No
browser or screen-reader check has been made for the menu; see the checkout's
compatibility evidence.

Filter/scopes DSL work, broader navigation extensions and the full Phase 2/release
Gates remain open. This API supplies no arbitrary destination URL, dynamic menu
Proc, record-count badge or general custom-action menu builder.

## Next Steps

* [Resources and Fields]({% link _core_features/resources-and-fields.md %}) defines the independent exposure/permission boundary.
* [List Navigation]({% link _core_features/list-navigation.md %}) retains bounded current-list hints through native workflows.
* [Template Overrides]({% link _advanced/template-overrides.md %}) tracks layout/menu compatibility on upgrade.
