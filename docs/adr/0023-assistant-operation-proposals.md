# ADR 0023: Assistants propose operations; only a human Surface submission executes

Status: implemented development contract (SPIKE-02 offline part); RAA-0251,
continuation (SPIKE-03), admin chat persistence and release gates remain open.

## Context

ADR 0020 made a native member-operation intent reviewable in a persistent
`raa_operation_review` Surface. The plan's next step is the offline part of
SPIKE-02: an assistant tool loop that presents a trusted component with
component-specific validation and ownership, exercised through the real
RubyLLM runtime rather than handwritten messages. The plan's approval rule
(§4.3.2) applies to every AI-initiated write, including low-impact ones. For
comparison, Avo's AI documentation (beta) allows an ordinary Create to execute
immediately. This project does not.

## Decision

`RailsAiAdmin::Integrations::ProposeOperation` is a `RubyLLM::Tool`
(`raa_propose_operation`). It is required on demand only and needs
`config.surfaces`. Operations opt in with `operation ..., assistant: true`, which
requires `surface: true` and grants nothing. The tool is built per request from
the authenticated admin Context and a server-owned `raa:conversation:<id>`
reference. Model output can supply neither. Its catalog lists only opted-in
member operations on resources the actor can currently index. Each operation's
declared input names and types appear in the description so the model can fill
them in.

Everything the model supplies (resource, record, operation, input) is untrusted.
The server checks catalog membership and the record-reference syntax. It then
loads the record through the policy scope and the operation's action grant, and
runs the normal `Runner#preflight` with `origin: :assistant`: input grants, typed
coercion, preflight purity and expiry. It then presents the review Surface. The
tool returns `presented` with the Surface id and an instruction never to claim
the change is done. It has no confirm path. Only the human's own CSRF-protected
Surface submission runs the shared Runner on that intent (audit origin
`surface`, intent origin `assistant`). The review text tells the user that an
assistant proposed it. Native and assistant intents cannot be presented through
each other's path.

A missing or foreign ToolCall cannot propose. Each provider tool call maps to one
UUIDv5 intent derived from the actor, tenant, conversation and call id
(`Runner#preflight` accepts a validated `intent_id`). A replay of the same call
re-coerces the same arguments, checks the intent digest and re-presents the same
Surface. A conflicting replay is rejected, and a replay after the human confirmed
returns `reviewed` before re-checking a command grant that the completed change
may have withdrawn. This works around DEP-011. Rejections return a code and only
the operation's declared input field names; foreign or missing records look
identical.

Provider configuration stays in an isolated `RubyLLM.context`. The admin never
reads or writes the host's global `RubyLLM.configure`. This step persists no
admin chat, usage or ToolCall rows. Callers own the chat object for now.

## Evidence

Direct tool tests cover the catalog, presentation without writes, replay,
conflicting replay, the post-confirmation replay, every untrusted-argument
rejection, missing and forged ToolCalls, the reviewer's own action grant, index
revocation, declaration guards and the human-only execution path. An offline test
drives a real RubyLLM chat (`protocol: :chat_completions`, HTTP stubbed by WebMock
with network disabled) through tool call, tool execution, tool result and final
answer. It checks the offered tool, the tool result sent back, that nothing was
written, the persisted intent and Surface, and the untouched global
configuration, on SQLite and PostgreSQL. Packaged Host B runs the same loop for
ticket triage beside its own RubyLLM product chat and default model, then a real
Devise session confirms with per-form CSRF: one write, one outbox item, both
asset pipelines.

## Not done

There is no admin Chat/Message persistence, no usage ownership, no streaming, no
continuation after confirmation (`transition.agent` stays false; SPIKE-03), no
paid or real-provider run, no Responses-protocol coverage and no provider schema
pairing study (SPIKE-02 real-provider part). The `input` argument is an open
object validated server-side; per-operation provider schemas remain open. The
plan's Order Review example became Host B ticket triage, because Host A must
stay AI-free.
