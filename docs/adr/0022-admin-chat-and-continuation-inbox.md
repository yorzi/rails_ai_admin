# ADR 0022: Admin Chat runs on a persistent turn inbox with fenced workers

Status: implemented development contract (SPIKE-03 offline evidence, RAA-0251
first slice). Supersedes ADR 0004's "assistant is not implemented" boundary for
this opt-in only. Real-provider behavior, streaming and Gate C remain open.

## Context

Public Preview needs one complete Chat+Surface workflow (plan §0.6). The plan
requires Engine-owned Chat/Message tables (§3.4), provider settings through
released `RubyLLM.context` (§6.4), human approval through the same intent as
native pages (§4.3.2), and a durable inbox that admits each human message or
Surface continuation exactly once (§6.8, SPIKE-03). The roadmap expected the
continuation to use rails_tool_views' `deliver(scope:, adapter:)`.

Released rails_tool_views 1.0.2 sets a new AgentInteraction's status from the
process-wide `agent_adapter` (`pending` when it is set, otherwise `skipped`),
and `deliver` returns without calling any adapter for a skipped interaction.
A host without a global adapter therefore never delivers through an explicit
admin adapter, and a host with one owns interactions the admin would need to
route. Using it would make admin Chat depend on host globals, which ADR 0020
rules out.

## Decision

`config.assistant = true` opts in. The host must load ruby_llm, run the
`rails_ai_admin:assistant` generator (Engine Chat, Message and Turn tables;
RubyLLM's shared `ruby_llm_models`, `ruby_llm_tool_calls` and `ruby_llm_usages`
only when absent), and name `config.assistant_adapter`, a class whose
`llm_context(context:)` returns a `RubyLLM::Context` or nil. nil means the
assistant is unavailable for that actor, a normal state. The admin never reads
or changes global RubyLLM configuration. Conventional hosts load no RubyLLM code
and draw no assistant routes; Host A still asserts `RubyLLM` is undefined.

**Grants.** A new default-deny `assistant?(context:, resource:)` grant decides
whether the model may see a resource at all. The pages exist for an actor only
when at least one resource grants it. Every tool call also applies the actor's
current index, show, read, search, filter and operation grants, so the model
never sees more than the same person could open.

**Storage.** `RailsAiAdmin::Assistant::Chat` and `Message` use RubyLLM 2.1.1's
`acts_as_chat`/`acts_as_message` with Engine table names. A chat belongs to one
actor, tenant and security version. Tool calls and usages live in RubyLLM's
shared tables, isolated per chat through their polymorphic columns (DEP-007);
a contract test with an equal-id product chat covers it. Usages are owned by the
admin chat itself (`RubyLLM.with_usage_owner(chat)`), so admin spend never
appears in a host owner's totals.

**Turn inbox (SPIKE-03).** A web request or Surface confirmation only admits a
turn, keyed per chat (`message:<uuid>` from the rendered form,
`intent:<operation run id>` for a continuation), then enqueues a job after
commit. A worker claims the lowest active turn of a chat under a five-minute
lease with an incremented generation; a later turn never overtakes it. Outside
any transaction, the worker:

1. rebuilds authority through the context adapter's read-only `resolve_job`
   (owner and security version must match, otherwise `AUTHORIZATION_REVOKED`);
2. persists the human message once, in a transaction that records it on the
   turn, so a retried worker continues the same conversation;
3. rebinds tools, versioned instructions (`persist: false`) and the provider
   context, because a loaded chat carries none of them;
4. drives RubyLLM with `step` until `complete?`, at most 12 steps, renewing the
   lease before every provider step and every tool call. A fenced worker stops
   before either; its completion or failure updates match only its own lease.

If a worker dies after RubyLLM persisted the final answer, the next claim finds
the chat `complete?` and finishes the turn without another provider call.
Provider errors retry up to three attempts with backoff; credential, model and
request rejections fail at once with a fixed code. The UI's **Try again**
requeues the saved turn and reuses its message. **Stop** cancels waiting turns
and asks a running one to stop at its next checkpoint through RubyLLM's
persisted cancellation; committed business results are never undone. Turns are
the admin's own `TurnCoordinator` equivalent (plan §6.4.1) and can be replaced
by upstream RubyLLM queue/claim primitives once those are released.

**Tools.** `list_resources`, `describe_resource`, `search_records` and
`get_record` return bounded JSON (16 KB, 20 records) through the shared list
query and projections; errors use generic codes, and a hidden or foreign record
is indistinguishable from a missing one. `propose_operation` (only with
`config.surfaces`) authorizes the member operation against its record, runs the
native preflight with `origin: :assistant`, and presents the existing
`raa_operation_review` Surface with the chat as its context and the persisted
tool call as its correlation. A retried tool call returns the same Surface
instead of preparing another intent. The tool writes no business data and has
no approval path.

**Continuation.** The human confirms in the Surface exactly as in ADR 0020. In
the same Surface-locked transaction as the business write, audit, receipt and
Surface revision, the confirmation admits one continuation turn whose text is
written by the server from the committed outcome. A replayed confirmation finds
the same `intent:` key and admits nothing. A closed chat never blocks the
business confirmation. This replaces `deliver(scope:, adapter:)` for the
reason above.

**Display.** Text is escaped plain text with no Markdown, links or remote
images. Stored tool output is never shown as is: record links are re-read
through current grants and Surfaces are restored through the admin scope. A
chat whose security version no longer matches shows no transcript. The page
polls a Turbo Frame while a turn is pending and offers a Refresh link without
JavaScript. No provider call runs in a web request.

## Evidence

Engine contract and request tests drive RubyLLM's real OpenAI provider,
chat-completions parser, tool loop and persistence against WebMock fixtures,
on SQLite and PostgreSQL. They cover a tool loop, admission keys and ordering,
retry without a repeated message, reconciliation of a persisted answer,
fencing before provider steps and tool calls, grant-filtered tools,
unavailable AI and revoked authority with no provider call, the step limit,
proposal replay, equal-id product chat isolation, the full HTTP flow from
message to Surface to one write and one continuation, private and closed chats,
retry, cancel, archive, Doctor and the generator. Mutation checks removing the
message once-guard, the continuation, the step fence, the tool fence and the
exposure grant each failed a test.

## Not decided or not done

No real provider has been called (SPIKE-02's provider half, RAA-0509). There is
no streaming, budget reservation (AI-012), per-tenant credential rotation,
aggregate or page-context tools (AI-010), or evaluation set. Instructions are a
fixed versioned constant, not host-overridable yet. Chats have no retention job.
Host B packaged evidence and a Chromium check are recorded separately in
`COMPATIBILITY.md` when run. Prompt injection is mitigated by data/instruction
separation, grants and human confirmation, not eliminated.
