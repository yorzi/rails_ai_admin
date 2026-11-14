# Roadmap

Rails AI Admin is a Public Preview. 0.3.0 was released on 2026-11-14. See [CHANGELOG.md](CHANGELOG.md) for changes and
[COMPATIBILITY.md](COMPATIBILITY.md) for version-specific validation evidence.

## 0.2.0: simpler setup (released)

- Rails 8.1.4.1+ within the 8.1 series, Ruby 3.3+, SQLite and PostgreSQL.
  Rails 7 and 8.0 are not supported.
- Detect existing Rails authentication or Devise, with host files preserved on rerun.
- Opt-in trusted-staff policy; default installation continues to deny policy access.
- Multiple and namespaced model generation, schema-based fields and explicit registration.
- Compact record lists, identity/sign-out controls and a collapsible mobile menu.
- Packaged fresh-app setup checks alongside independent host and recovery tests.

These changes do not establish adoption or production suitability for every host.
An independent app trial and human screen-reader review remain open. A hosted
read-only demo is a future task, not part of this release's claim.

## 0.3.0: everyday list work (released)

- `contains`, `in` (any of) and `blank` filters, declared per field.
- Sorting and searching by a `belongs_to` reference, under the target's grants.
- Numbered pages for counted lists, and personal saved views.
- One-step bulk delete and collection operations from the list, including all
  matching records up to 100, still through their review pages.
- Soft delete with a Deleted records page and a separate restore grant.
- Editing children from the parent page, returning there after saving.
- A doctor summary line and a problems-only mode.

## Next candidates

Prioritize from actual host use rather than a fixed release calendar:

- OR filters and filters across more than one association.
- Child forms that save with the parent, polymorphic references and separately
  controlled attachment changes.
- Bulk operations over more than 100 records as an asynchronous job.
- Assistant token/cost budgets, conversation retention and aggregate queries.
- Current native-provider checks, more locales and additional policy adapters.

No date or version is committed for these candidates. Beta and 1.0 require broader
host validation, stable contracts and evidence beyond the local test suite.
