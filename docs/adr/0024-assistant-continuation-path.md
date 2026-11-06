# ADR 0024: Assistant continuation path after Surface confirmation (open decision)

Status: historical alternatives, superseded by [ADR 0022](0022-admin-chat-and-continuation-inbox.md). The admin-owned turn inbox is implemented; the released SDK constraint remains characterized by the contract test.

## Context

After a human confirms an assistant-proposed review (ADR 0023), the assistant
should continue the conversation exactly once, after the business transaction
commits, without the host's global rails_tool_views adapter (plan §6.3.1 item 4,
§6.8, SPIKE-03).

rails_tool_views 1.0.2 creates the follow-up `AgentInteraction` as `pending` only
when the host's global `agent_adapter` is configured; otherwise it is `skipped`,
and `deliver` treats `skipped` as terminal, even when an explicit adapter is
passed (DEP-013). `test/integration/tool_views_continuation_contract_test.rb`
proves both cases against the released gem. Packaged Host B, like many hosts,
sets no global adapter. Configuring one from the admin would change host-owned
runtime behavior, which ADR 0020 rules out.

## Options

A. **Upstream fix in rails_tool_views (recommended).** Create follow-ups as
   `pending` whenever a transition requests one, or support an explicit-delivery
   flag. Then the admin sets `agent: true` for assistant-origin confirmations and
   calls `deliver(scope:, adapter:)` after commit with an admin adapter that
   resumes the admin chat. It reuses the gem's lease, fencing, uncertain-delivery
   and reconciliation machinery, which is the plan's stated preference over a
   second state machine. Cost: a rails_tool_views release and a version-bound bump.

B. **Admin-owned continuation inbox.** Admit a continuation row in the same
   Surface transaction as the confirmation and deliver it after commit with its
   own lease, fencing and reconciliation, independent of `AgentInteraction`. It
   works with 1.0.2, but it duplicates a durable state machine the plan wants to
   avoid. The existing admin outbox cannot be reused as-is, because it
   deliberately blocks ordinary Active Record writes, and resuming a RubyLLM chat
   persists messages.

C. **Require hosts to configure a global adapter.** Rejected: it changes
   host-owned behavior for the host's own product Surfaces (ADR 0020).

## Consequences before ADR 0022

Assistant proposals and human confirmation work (ADR 0023); the assistant is
not notified of the outcome. Admin chat persistence is independent of this
decision and can proceed: an opt-in generator must create the admin chat and
message tables, because they reference RubyLLM's shared `ruby_llm_models`
table, which conventional hosts do not have.
