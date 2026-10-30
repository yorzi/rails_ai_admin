# ADR 0010: Computed fields use authorized dependency snapshots

Status: implemented development contract; owner review and the full Phase 2 gate
remain open.

A `virtual` field selects a core scalar or registered scalar type, declares
`depends_on` field names and references a named `Fields::Computation` subclass by
string. The public hook is `call(values, field:, time_zone:)`. Virtual fields are
readonly and cannot become generic write, search, sort, Operation input or Work
input targets. Declaring one never enables arbitrary model method invocation.

The field and every node in its dependency closure need their own current read
grant. A denied dependency suppresses the computed field before its getter or
computation runs. Missing declarations, cycles, more than 128 fields on a computed
resource, more than 20 direct dependencies or more than eight virtual levels fail
metadata validation without consulting domain schema or rows. This is not a way
to declassify hidden data through an aggregate.

One projection owns the dependency cache. It reads/evaluates diamond dependencies
once and shares its values with the native row title. Only declared scalar
snapshots enter each computation; strings/dates are copied, temporal values become
independent UTC Time copies, and the hash/values are frozen. Unknown objects are
rejected. Output is parsed through the same scalar/plugin contract used elsewhere.
The dependency hash, each dependency and computed value fit 16 KiB canonical JSON;
computed outputs together fit 64 KiB per projection. A cooperative one-second
budget covers every read and the final return of a computed projection. It does
not interrupt running Ruby, SQL or external I/O.

All physical getters use the ordinary Active Record write-prevention guard,
including early-cached dependencies and direct physical titles. Computation and
coercion also run behind that guard. Hooks, model getters and templates remain
trusted Ruby; this is not a sandbox or a ban that Ruby code cannot bypass. Hosts
must keep them pure and must not fetch extra records or log private snapshots.
Native errors omit the original computation diagnostic.

Pages, fixed Selections and collection jobs share the current authorized title
formatter and 120-character bound. A denied title/dependency falls back to
`Record #id`; authorized nil/false remain values. Virtual values are not persisted
in selections or receipts. Custom preflight cannot fabricate their before/after
values: virtual change entries are excluded, and committed results recompute the
actual current projection.

Computation class/version and dependency edges enter the existing Field contract,
so rebuilt definitions invalidate affected approvals, selections and Work
signatures. Runtime lookup resolves the current class and rejects stale metadata.
Semantic changes require an explicit version bump. Actual Rails source reload in
packaged Host B verifies this behavior without changing host SDK configuration.

This completes bounded readonly scalar computation, not full-page overrides,
form/session recovery, all field presentation controls or the three-domain-resource
Phase 2 acceptance. See the [computed field guide](../site/_core_features/computed-fields.md).
