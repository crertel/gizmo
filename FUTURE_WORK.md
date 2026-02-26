# Future Work

Ideas that aren't on the current roadmap but could be worth revisiting later.

## Frame Tagging

Tag frames with metadata like `code`, `quote`, or security taint markers. This
could enable:

- **Taint tracking for prompt injection.** Mark frames derived from untrusted
  input (user messages, external API responses) so downstream ops can treat
  them differently—e.g., refusing to `send` to `bash` from a tainted frame.
- **Rendering hints.** A `code` tag could tell the human adapter to syntax
  highlight, or a `quote` tag could indicate verbatim content that shouldn't
  be paraphrased by the LLM.
- **Audit trails.** Tags could record which op or cycle produced a frame,
  making the context stack's history inspectable.

No concrete design yet. The mechanism (how tags are attached, propagated, and
checked) matters more than the use cases listed above.

## Cognitohazard Vault (Secrets Mechanism)

A vault for values that should never appear in LLM context or message content.
Agents refer to vault entries via opaque handles like `~SECRET_API_KEY` or
`~LONG_CONTEXT_BLOB`. The handle is what the LLM sees and manipulates — the
actual value is never interpolated into prompts, ops, or frames.

The vault stores each entry alongside a hash and/or a short summary so the
runtime can verify integrity and give the LLM enough information to reason
about the value without seeing it. This prevents both prompt injection (a
malicious payload in a secret never reaches the LLM) and inadvertent leaking
(the LLM can't echo what it never saw).

Open questions: vault population (CLI flags, env vars, boot frame directives),
handle syntax (`~name` vs something else), whether summaries are auto-generated
or author-provided, and how vault entries interact with interpolation order.

## Pledge-for-Address

Restrict which mailboxes an agent can `send` to. At spawn time (or in the boot
frame), declare an allowlist of mailbox IDs or patterns. The runtime rejects
any `send` op targeting a mailbox not covered by the pledge.

This limits blast radius — a child agent spawned to query `bash` and report
back to `${_parent}` shouldn't be able to send to `human_input`, `reaper`, or
arbitrary other agents. Combined with the cognitohazard vault, it constrains
both what an agent can say and who it can say it to.

Open questions: pledge syntax (allowlist vs denylist, literal IDs vs patterns),
whether pledges are inherited by children, enforcement on `spawn` (can a parent
grant a child more access than it has?), and whether violations are silent drops
or fatal errors.

## Pledge-for-Content

Restrict what content an agent can send. Specify patterns — literal strings,
regexes, or vault handle references — that are redacted or rejected when they
appear in outbound `send` message content.

This is the content-level complement to pledge-for-address. A vault entry like
`~SECRET_API_KEY` defines both the opaque handle (for the LLM) and a redaction
pattern (for the runtime to enforce). If an agent somehow reconstructs or
receives the raw secret and tries to send it, the pledge-for-content check
catches it.

Open questions: redaction vs rejection (replace with `[REDACTED]` vs fail the
op), pattern source (inline in pledge vs vault references), interaction with
`spawn` frames (are patterns checked in child frame content at spawn time?),
and performance cost of regex scanning every outbound message.
