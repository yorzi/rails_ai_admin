# ADR 0026: Multi-actor approval and separation of duties

Status: implemented development contract (`0.7.0` slice). Extends ADR 0006, ADR 0008, and ADR 0020.

## Context

Through `0.6.0`, every `OperationRun`, `Selection`, `Assistant::Chat`, and `RailsToolViews::Scope` bound a single `actor_ref`: only the actor who prepared an intent could view, confirm, or replay it (`OperationRun.find_by(id:, actor_ref:, tenant_ref:)`, `Collections::Contract.verify_approved!` asserting `approved_by_ref == actor_ref`). High-risk administrative mutations (such as refunds, merges, or sensitive state overrides) often require **four-eyes review** (separation of duties), where one operator or assistant session proposes an intent and a distinct authorized reviewer in the same tenant approves and executes it.

At the same time:
- `RailsToolViews::Scope` (`rails_tool_views ~> 1.0.2`) binds each Surface to one `(actor, tenant)` pair (`DEP-009`).
- Background collection and outbox workers (`Collections::Claim#context`, `Outbox::Dispatcher#authorize`) reconstruct authority via `resolve_job(actor_ref:, tenant_ref:, security_version:)`.
- Unmigrated hosts or default `:self` operations must preserve exact prior behavior.

## Decision

1. **Explicit `approval_mode` per operation (`:self`, `:separate_actor`, `:any_reviewer`):**
   - `Operation.approval_mode` defaults to `:self`; resources may declare or override `operation :key, handler: "...", approval: :separate_actor` (or `:any_reviewer`).
   - `approval_mode` participates in `Operations::RunnerFingerprint` (`Definition#signature`), so tightening an operation's approval requirement immediately invalidates unconfirmed intents.

2. **Proposer vs. approver provenance on `OperationRun` and `AuditEvent`:**
   - `rails_ai_admin_operation_runs` records `proposed_by_actor_ref` (immutable proposer identity), `approval_mode`, `approver_security_version`, and optional bounded `approval_note` (<= 500 plain-text chars), plus bounded wire `input_payload` for non-secret custom/multi-actor member proposals so reviewers can inspect and confirm without the proposer's browser tab.
   - `rails_ai_admin_audit_events` records `proposed_by_actor_ref` alongside `actor_ref` (the actor who confirmed/executed or rejected the attempt).

3. **Confirmation, separation-of-duties, and worker authority handoff:**
   - `:self` mode keeps strict single-actor lookup (`actor_ref == context.actor_ref` and `security_version == context.security_version`).
   - `:separate_actor` and `:any_reviewer` look up proposed intents within `tenant_ref == context.tenant_ref`.
   - `:separate_actor` refuses confirmation when `context.actor_ref == proposed_by_actor_ref` with code `SELF_APPROVAL_FORBIDDEN` (audited as a rejected event, zero domain writes).
   - Confirming a `:separate_actor` or `:any_reviewer` intent requires the **approver's** live grants:
     1. `Authorization::Access#authorize_approval!(operation, record, proposed_by_actor_ref:)` delegating to `Adapter#approve_operation?` (default `false` in both `Adapter` and `FullAccessAdapter`, strict `== true` in `PunditAdapter`).
     2. Live `authorize!(operation, record)`, policy scope membership, field/input grants, and matching `input_digest` + `expected_version` (for collections, re-validating every `SelectionItem` target under the approver's scope and grants).
   - Upon confirmation/admission, `OperationRun` binds `actor_ref = context.actor_ref` (the approver), `security_version = context.security_version`, `approved_by_ref = context.actor_ref`, and `approver_security_version = context.security_version`, while retaining `proposed_by_actor_ref`. Consequently, downstream `Collections::Claim` and `Outbox::Dispatcher` workers resolve the **approver's** live authority and fail closed if the approver's access or `security_version` is revoked.
   - Receipt reads (`status == "succeeded"` or admitted collection runs) permit either `actor_ref` (approver) or `proposed_by_actor_ref` (proposer) within the same `tenant_ref`, subject to current `authorize_receipt!`.

4. **Surface boundary preservation:**
   - Chat-embedded `raa_operation_review` Surfaces remain scoped to the proposer's `(actor, tenant)` `RailsToolViews::Scope`. When `approval_mode == :separate_actor`, the proposer's Surface renders a pending-reviewer notice without a Confirm button (and server `confirm` denies self-approval if invoked directly). Cross-actor review and confirmation occur through admin-owned approval endpoints and the Approval Inbox (`E05`).
