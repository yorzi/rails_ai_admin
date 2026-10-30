# ADR 0009: Scalar field extensions refine the core contract

Status: implemented development contract; owner review and the full Phase 2 gate
remain open. No stable 1.0 API is declared.

The registry constructs `RailsAiAdmin::Field`. A host registers a named subclass
of `RailsAiAdmin::Fields::Type` by string in `config.field_types`; it does not
replace or subclass the core field object. This composition keeps exposure,
readonly flags, policy filtering, coercion and operation fingerprints under one
core implementation. Built-in keys cannot be replaced.

Each type selects a built-in scalar and supplies pure `normalize`, `valid?`,
`format` and `schema` hooks plus optional form/index/show partial paths. Hooks get
an immutable field descriptor and scalar, never a domain record. Ordinary Active
Record writes are prevented while hooks run. This is a guard for accidental writes,
not a Ruby sandbox: host code, model getters and Rails partials remain trusted.
No extension may treat registration or presentation as a policy grant.

Normalize is checked for idempotence, and its result is parsed through the core
scalar again before validation. The extension's JSON Schema is intersected with
core constraints and validated on canonical wire values. Only type-applicable
scalar keywords are accepted. Decimal uses a string wire representation; numeric
ranges belong in `valid?`. Nil follows the core nullable flag and skips type hooks.
No parallel validation DSL or dependency-private schema API is introduced.

Format returns bounded plain text. HTML-safety flags are removed before ordinary
ERB escaping. A trusted partial receives only the already-authorized field value
and display text (or form builder/options). The index skips both formatter and
partial when the per-record projection lacks that field; an authorized nil value
still renders. These locals do not restrict access to Rails globals or instance
variables, so host partials need their own review.

Registries store class-name strings and resolve current classes. Reload rebuilds
registries/resources, and field contracts include type/version/options/schema/
partial paths in operation, selection and Work fingerprints. A semantic hook or
partial change must bump the type version. Old confirmations must be rejected;
reload is not a migration of durable approvals.

Fixed Select has distinct display labels and string values, bounded immutable
choices and explicit blank/null parsing. Unknown stored/submitted values remain
visible as disabled selections until the user chooses a current option; the form
must not silently replace them. Readonly fields still require physical scalar
attributes or the supported primary-key alias. Virtual/computed fields,
ViewComponent-specific adapters, full-page override generators and upgrade
compatibility diagnostics remain separate work.

See the [field guide](../site/_core_features/field-types.md) and
[extension reference](../site/_reference/extension-contracts.md). Contract/request
regressions, both packaged hosts and real development reload exercise this API;
local evidence does not close browser, independent adoption or release gates.

Follow-up, 2026-10-30: ADR 0010 adds bounded readonly Virtual/computed fields
through dependency snapshots. Full-page overrides and the other remaining
extension/Phase 2 requirements above are still open.

Follow-up: ADR 0011 adds individual overrides for the current conventional page
and field templates. Surface wrappers and remaining extension contracts are open.
