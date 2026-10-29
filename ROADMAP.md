# Roadmap

The detailed requirements remain in rails_ai_admin_development_plan.md.
Unchecked gates remain required; implementation progress does not approve release.

1. Foundation: contracts, isolated Engine, fail-closed adapters and typed resources.
2. First vertical slice: authorized Customer CRUD, server intents, version checks,
   atomic operation receipts and audit, packaged installation and recovery tests.
3. Early integration proof: Order Review through ordinary UI and a trusted Surface,
   using the same operation. Offline RubyLLM loop before paid provider testing.
4. Conventional admin: associations, batch, CSV, private files and dashboards.
5. Productized assistant: isolated chat, quotas, revocation and durable continuation.
6. Migration, independent usability/security review and release gates A through E.

The first implementation pass targets items 1 and 2. Partial spike evidence must
be identified by database and host; it cannot close a full multi-host gate.
