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

## OpenAI-Compatible Backend Hardening

The OpenAI client (`Gizmo.LLM.OpenAI`) works but needs hardening for local
models (LM Studio, ollama, etc.):

- **`additionalProperties: false`** on the eval schema at both the top-level
  object and op items object. Required by OpenAI's strict JSON schema mode and
  enables grammar-based constraining in local servers.
- **Backend auto-selection.** `setup_runtime` and `init_agent` should select
  the OpenAI backend when `ANTHROPIC_API_KEY` is absent, instead of always
  defaulting to Anthropic.
- **Rename spawn `model` field to `eval_model`.** The field name `model` is
  too easily confused with `msg` by small local models — both are short string
  fields on the same flat union schema. `eval_model` is unambiguous.

Tested with phi-4-reasoning-plus (14B), devstral-small (14B), and
ministral-3-14b-reasoning. All consistently garbled send ops (using `model`,
`dest`, or `frames` instead of `msg`). The schema fixes help with constraining
but can't overcome models that don't understand "which fields go with which op
type" in a flat union. Likely need 30B+ with strong instruction tuning for
reliable structured output.

## Self-Modifying Runtime (Blue-Green Gizmo)

Agents can already rewrite their own context stacks — that's the core eval
loop. But the runtime itself (`gizmo.exs`) is immutable once the BEAM loads
it. Except: the BEAM loads scripts once at startup, so the file on disk is
free game after that. This opens a path to agents that evolve their own
execution environment.

### The chain

1. **Agent persistence.** Prerequisite. Agents need to survive VM transitions.
   Sqlite or equivalent — serialize agent state (context stack, bindings, trap,
   mailbox contents) to disk. Not a hard problem, just needs doing.

2. **BEAM clustering.** A running gizmo instance spawns a *new* BEAM process
   running a modified `gizmo.exs`. The two VMs connect via Erlang distribution
   (cookies). This is standard BEAM — `Node.connect/1`, named processes,
   message passing across nodes. The new VM is disowned by the spawning OS
   process so the parent can die independently.

3. **Blue-green deploy.** The new VM starts, runs health checks (smoke tests,
   agent hello-world). If it passes, the old VM serializes agent state,
   transfers it to the new VM, and shuts down. If it fails, the new VM dies
   and the old one continues unchanged. Zero-downtime runtime evolution.

4. **Git-backed runtime mutation.** Agents use the bash service (or a
   dedicated git service) to modify `gizmo.exs` on a branch, commit, spawn
   the new BEAM from that branch, and test it. On success: merge and promote.
   On failure: `git checkout` and the old runtime is untouched. Full version
   history of every runtime mutation, with rollback for free.

5. **The loop.** An agent's boot frame says "improve the runtime." It reads
   `gizmo.exs`, reasons about a change, writes the change, commits to a
   branch, spawns a new BEAM, runs the test suite against it, and either
   promotes or rolls back. Then it does it again. Self-modifying infrastructure
   in a tight loop with git as the safety net.

### Isolation levels

The above assumes trust in the modified runtime not to do something
catastrophic to the host (rm -rf, network exfil, etc.). Increasing isolation:

- **OS process isolation (default).** The new BEAM is just a child process.
  Shares the filesystem and network. Cheapest, least safe. Fine for
  experiments where the human is watching.

- **Nix sandbox.** The repo is already a Nix flake. `nix build` the modified
  runtime in a sandbox with restricted network and filesystem access. The
  build output is a known-good closure. Run the new BEAM from the Nix store
  path — it can't see or modify the source tree.

- **NixOS VM (maximum safety).** `nixos-rebuild build-vm` or QEMU via the
  flake. The modified runtime runs in a fully isolated virtual machine with
  its own filesystem, network namespace, and resource limits. The host
  observes the VM's behavior (did tests pass? did it try to phone home?) and
  decides whether to promote. The agent literally cannot damage the host even
  if the modified runtime is adversarial.

Each level trades speed for safety. The Nix VM path is slow but lets you
hand an agent the keys to its own runtime with confidence that the worst
case is a wasted VM boot, not a wrecked host.

### Open questions

- **State serialization format.** What exactly gets persisted? Context stack
  and bindings are obvious. Trap state, message queue contents, cycle count,
  sections cache — less clear. Need a clean boundary between "agent state"
  and "runtime state."
- **Migration protocol.** How do agents in flight handle the transition?
  Drain to a quiescent state first? Or hot-migrate mid-cycle? BEAM
  distribution supports message forwarding, but the eval loop has assumptions
  about local process state.
- **Multi-agent coordination during migration.** If agents A and B are
  mid-conversation and the runtime migrates, their mailbox routing must
  survive the transition. Registry entries need to transfer atomically.
- **Convergence.** What stops a self-modifying loop from oscillating? The
  test suite is the obvious fitness function, but "passes tests" doesn't
  mean "is better." May need a human-in-the-loop approval gate, at least
  initially.
- **Diff review.** Even with git history, a human should probably review
  runtime diffs before promotion. A `human_input`-style gate: "The agent
  wants to change the runtime. Here's the diff. Approve?"
