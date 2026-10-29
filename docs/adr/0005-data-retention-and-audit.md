# ADR 0005: Minimal append-only execution evidence

Status: implementation decision, owner review pending.

Audit stores typed identities, resource/operation, safe record ref, changed field
names, outcome and correlation. Do not store credential values, raw inputs, before
and after snapshots or custom validation messages. Append-only is an application
constraint; database administrators and direct SQL can bypass it.

Successful audit and intent receipt use the domain transaction. Rejections/failures
are separate events and never imply committed business effects. Retain intent
rows through the full replay window; unknown and expired IDs cannot be recreated
from submitted content. No automatic deletion job is provided in this slice.
Audit Explorer, encrypted values and retention/purge workflows remain later work.
