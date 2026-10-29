# Threat model

Assets are host business records, tenant boundaries, credentials and operation
evidence. Actors include anonymous users, low privilege admins, stale sessions,
malicious submitted values, concurrent retries and future untrusted model output.

| Boundary | Required control | First-slice verification |
| --- | --- | --- |
| Request to context | Host authentication, fail closed | 401 with no adapter/context |
| Context to relation | Explicit SQL scope and action policy | Cross-tenant lookup/list tests |
| Input to attributes | Declared typed schema and current field policy | Unknown/hidden/readonly values rejected |
| Intent to domain write | Identity/version/digest/expiry binding | Replay, mutation and revocation tests |
| Write to audit | Same pool and database transaction | Forced audit failure rolls back domain |
| Record to HTML | Rails escaping, no-store, CSP | Malicious record text and CSRF tests |
| Restart to retry | Durable intent, database locks | Packaged/fresh-process replay and contention |

Generic CRUD executes host validations/callbacks. Hosts must keep resources
readonly if these have irreversible effects. No runtime inspection can prove a
callback safe. Ruby extensions and the database administrator are trusted.
AI injection, private attachments, streams, external effects and background
workers require further controls and are unavailable in this slice.

Local automated review does not constitute an independent security audit.
