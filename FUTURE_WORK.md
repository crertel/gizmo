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

No concrete design yet.

### Open questions

- How are tags attached — op field, frame wrapper, or runtime annotation?
- How do tags propagate through interpolation and spawn?
- Who checks them — the runtime, the LLM, or both?

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

The vault could also double as a way to pass binary data between agents.
Binary blobs (images, compiled artifacts, serialized state) can't appear in
LLM context, but agents could store them in the vault, pass the opaque handle
via messages, and have the receiving agent or service dereference the handle
at the runtime level.

### Open questions

- Vault population — CLI flags, env vars, or boot frame directives?
- Handle syntax — `~name` vs something else?
- Are summaries auto-generated or author-provided?
- How do vault entries interact with interpolation order?

## Pledge-for-Address

Restrict which mailboxes an agent can `send` to. At spawn time (or in the boot
frame), declare an allowlist of mailbox IDs or patterns. The runtime rejects
any `send` op targeting a mailbox not covered by the pledge.

This limits blast radius — a child agent spawned to query `bash` and report
back to `${_parent}` shouldn't be able to send to `human_input`, `reaper`, or
arbitrary other agents. Combined with the cognitohazard vault, it constrains
both what an agent can say and who it can say it to.

### Open questions

- Pledge syntax — allowlist vs denylist, literal IDs vs patterns?
- Are pledges inherited by children?
- Enforcement on `spawn` — can a parent grant a child more access than it has?
- Are violations silent drops or fatal errors?

## Pledge-for-Content

Restrict what content an agent can send. Specify patterns — literal strings,
regexes, or vault handle references — that are redacted or rejected when they
appear in outbound `send` message content.

This is the content-level complement to pledge-for-address. A vault entry like
`~SECRET_API_KEY` defines both the opaque handle (for the LLM) and a redaction
pattern (for the runtime to enforce). If an agent somehow reconstructs or
receives the raw secret and tries to send it, the pledge-for-content check
catches it.

### Open questions

- Redaction vs rejection — replace with `[REDACTED]` or fail the op?
- Pattern source — inline in pledge or vault references?
- Are patterns checked in child frame content at spawn time?
- Performance cost of regex scanning every outbound message?

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

## Session Persistence and Snapshotting

Agent state is currently ephemeral — when the BEAM shuts down, all agent
context stacks, bindings, mailbox contents, and trap registrations are lost.
Session persistence would serialize agent state to durable storage so agents
can be suspended and resumed across VM restarts.

The simplest backend is SQLite or DETS (Erlang's built-in disk-based term
storage). Either works for single-machine use: snapshot an agent's state
(context stack, bindings, trap, message queue, cycle count, sections cache)
as a single record keyed by mailbox ID. DETS is zero-dependency on the BEAM
but limited to 2 GB and single-node; SQLite is more robust and inspectable
from outside Elixir.

Eventually the storage backend could be a remote database or filesystem —
Postgres, S3, or a networked KV store — enabling agents that migrate between
machines or survive host failures. The serialization format should be
backend-agnostic so swapping storage is a configuration change, not a
rewrite.

This is also a prerequisite for the self-modifying runtime (below): agents
need to survive VM transitions for blue-green deploys to work.

### Open questions

- What exactly constitutes "agent state" vs "runtime state"?
- Snapshot granularity — per-cycle, on-demand, or on idle?
- Do snapshots include in-flight message queue contents?
- How to handle stale references (a resumed agent's `_parent` may no longer exist)?

## Debug Visualization

The current debugging tools (`-v` flags, `--trace` NDJSON, `--dry-run`) are
text-based and post-hoc. Better visualization could make multi-agent systems
significantly easier to understand and debug.

Possible directions:

- **Live message sequence diagrams.** Render agent-to-agent and
  agent-to-service message flow as a sequence diagram in real time. Show
  send/receive causality, message content, and timing.
- **Context stack inspector.** Visualize the context stack as a
  live-updating list of frames, with interpolation results shown inline.
  Highlight which frame the LLM is "in" and how frames change across cycles.
- **Binding timeline.** Show how each binding evolves over cycles — when it
  was created, overwritten, or reset (on idle restore). Useful for
  diagnosing stale-binding bugs.
- **Agent lifecycle view.** A tree or graph showing spawn relationships,
  agent status (running, idle, terminated), and death notifications.
  Especially useful for multi-agent systems with disowned peers.
- **Trace replay.** Load a `--trace-file` NDJSON trace and step through it
  cycle-by-cycle, with full system prompt, user message, ops, and frames
  visible at each step.

### Open questions

- Terminal UI (e.g. Ratatui via a Rust sidecar) or web UI (e.g. LiveView dashboard)?
- How to handle high-frequency grind-mode agents without overwhelming the display?
- Separate tool or integrated into the runtime?

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
