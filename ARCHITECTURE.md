# Gizmo Architecture

Gizmo is a minimal runtime for LLM agents modeled on process calculus and the
BEAM. An agent is a process with a context stack, a mailbox, and four ops.
Everything else—tool use, memory, multi-agent coordination, human
interaction—is built on top as mailbox-backed services.

## Key Principles

- **Eval is the loop, not an operation.** The runtime calls the LLM in a loop.
  The LLM is the rewrite rule; the context stack is the string being rewritten.
- **Four ops only.** `send`, `receive`, `spawn`, `trap`. No
  special-cased tool calling, memory, or orchestration primitives.
- **Everything is a mailbox.** Bash, a key-value store, a human, another
  agent—same interface. The agent doesn't know or care what's behind a mailbox.
- **The context stack is the prompt.** Frames are concatenated bottom-up and
  sent to the LLM. The boot frame is always the prefix, enabling prompt
  caching.

## Process Model

```
┌─────────────────────────────┐
│         Agent Process       │
│  (plain process via         │
│   :proc_lib / Wrapper)      │
│                             │
│  context_stack: [frame]     │  ← the prompt, bottom-up
│  mailbox_id:    mb_id       │  ← address for receiving messages
│  parent_id:     mb_id|nil   │  ← ${_parent} binding
│                             │
│  trap:           {regex, frames}|nil
│  grind:          bool           │
│                                 │
│  eval loop:                     │
│    wait for message (or grind)  │
│    check trap → prepend handler │
│    concat stack → LLM           │
│    LLM → {ops, frames}         │
│    execute ops                  │
│    replace stack with frames    │
│    repeat                       │
└─────────────────────────────────┘
```

By default, agents **terminate** when the context stack drains to `[]`.
With `--idle`, the boot frame is restored instead and the agent waits for
new messages — useful for long-running daemon-style agents.

## Ops

| Op | JSON format | Behavior |
|---------|-----------|----------|
| `send`  | `{"op": "send", "mailbox": "...", "msg": {...}}` | Async fire-and-forget message to any mailbox. `msg` is always a JSON object. Non-blocking. |
| `receive` | `{"op": "receive", "dest": "..."}` | Block until a message arrives. Text summary stored in `dest`, full JSON in `dest_payload`. |
| `spawn` | `{"op": "spawn", "frames": [...], "dest": "..."}` | Create child process with given frames. Child mailbox ID stored in binding `dest`. Optional fields: `grind` (override loop mode), `idle` (override exhaust behavior), `disown` (no `_parent` binding, no death monitor), `name` (custom mailbox ID instead of auto-generated), `model` (override LLM model for child). |
| `trap` | `{"op": "trap", "pattern": "...", "frames": [...]}` | Register interrupt handler. PCRE regex pattern matched against inter-cycle messages. On match, handler frames prepend to stack. Empty frames clears the trap. |

All message content is interpolated (`${name}` from bindings) at operation
time.

## Well-Known Services

These are supervised processes with fixed mailbox names, registered at boot
by `Gizmo.Supervision`. They are not syscalls.

| Service | Mailbox | Purpose |
|---------|---------|---------|
| **blackboard** | `"blackboard"` | Key-value store. Shared memory. `{"action": "read", "key": "..."}` / `{"action": "write", "key": "...", "value": "..."}`. |
| **bash** | `"bash"` | Shell command execution. `{"command": "..."}` with optional `"timeout"`, `"mode"`, `"note"`. |
| **human** | `"human"` | Terminal output. `{"text": "..."}`. |
| **human_input** | `"human_input"` | Terminal input. `{"prompt": "..."}`, responds with user's typed line. |
| **exception** | `"exception"` | Error notification sink. Receives agent retry/cycle exhaustion reports. |
| **reaper** | `"reaper"` | Agent lifecycle. `{"target": "<mailbox_id>"}` to kill a descendant. |
| **watchdog** | `"watchdog"` | Timer service. `{"action": "every/after/cancel/list", "ms": N}`. |
| **pager** | `"pager"` | Document pager. `{"action": "open", "path": "..."}` spawns a per-document session. |
| **batch** | `"batch"` | Fan-out parallel requests. `{"requests": [...], "timeout": N}` → collects all results. |
| **eval** | `"eval"` | Evaluate Elixir expressions. `{"code": "...", "timeout": N}` with AST allowlist sandboxing. |
| **factory** | `"factory"` | Create custom stateful services at runtime. `{"action": "create", "name": "...", "code": "fn msg, state -> ... end", "state": init}`. Workers register as their own mailbox. |
| **migration** | `"migration"` | Live runtime migration. `{"action": "migrate", "script": "/path/to/gizmo.exs"}` snapshots all agents and services, spawns a new BEAM via `:peer`, transfers state, and shuts down the old node. Requires `--node` and `--cookie`. |

Per-agent state (not well-known, created per agent instance):

| Component | Scope | Purpose |
|-----------|-------|---------|
| **bindings** | in-process | Named bindings map. Values from `receive` (`dest` + `dest_payload`), `spawn` (`dest`), runtime (`_self`, `_parent`, `_msg`, `_payload`, `_msg_source`), and error recovery (`_op_error`, `_pending_ops`). Threaded through eval loop. |
| **messages queue** | per-agent | FIFO queue of `{content, source}` tuples. Each agent gets its own `MessagesQueue` GenServer. Currently unused in the runtime path (write-only scaffolding removed); the module is retained for test assertions. |

## Eval Loop Detail

```
1. Wait for message (message-driven mode):
   a. First cycle: no wait, _msg="init", _msg_source="runtime"
   b. Grind mode: no wait, loop immediately
   c. Default: block on receive, bind _msg/_msg_source
   d. If trap matches: bind _interrupt/_interrupt_source, prepend handler frames
2. Concatenate runtime prompt + all context stack frames → system prompt
3. Build user message: "Begin." + current bindings
4. Call LLM with system prompt and user message
5. LLM returns structured {ops, frames, notes} via eval_response tool
6. Interpolate frames and op strings against bindings and sections
7. Execute ops sequentially (may update bindings via receive/spawn, trap state).
   If an op fails, remaining ops are skipped and _op_error/_pending_ops are bound.
8. Replace context stack with returned frames
9. If stack is empty:
   a. Default → agent terminates
   b. If idle mode and boot frame exists → restore boot frame (idle)
   c. If no boot frame → agent terminates
10. Goto 1
```

The stack is **self-reducing**:
- 0 replacement frames → stack shrinks (work done)
- 1 replacement frame → continuation
- N replacement frames → task decomposition

## LLM Output Format

The LLM returns structured JSON via a forced tool call (`eval_response`).
The response contains three fields: `ops` (syscalls to execute), `frames`
(replacement frames for the context stack), and `notes` (binding annotations).

```json
{
  "ops": [
    {"op": "send", "mailbox": "human", "msg": {"text": "I'll check the files."}},
    {"op": "send", "mailbox": "bash", "msg": {"command": "ls -la"}},
    {"op": "receive", "dest": "listing"}
  ],
  "frames": [
    "Process the directory listing in ${listing}."
  ],
  "notes": {"listing": "output of ls -la"}
}
```

Each op is an object with an `"op"` field and op-specific parameters:

| Op | Fields | Example |
|----|--------|---------|
| `send` | `mailbox`, `msg` | `{"op": "send", "mailbox": "bash", "msg": {"command": "ls"}}` |
| `receive` | `dest` | `{"op": "receive", "dest": "output"}` |
| `spawn` | `frames`, `dest`, [`grind`], [`idle`], [`disown`], [`name`], [`model`] | `{"op": "spawn", "frames": ["child task"], "dest": "child", "disown": true}` |
| `trap` | `pattern`, `frames` | `{"op": "trap", "pattern": "^alert:", "frames": ["handle ${_interrupt}"]}` |
| `trap` (clear) | `pattern`, `frames=[]` | `{"op": "trap", "pattern": ".*", "frames": []}` |

The schema is enforced by the LLM provider (Anthropic tool_use with forced
tool_choice, OpenAI structured outputs with json_schema). This eliminates
parsing ambiguity and the need for a text parser.

## Interpolation

- `${name}` — named binding resolved from bindings map (populated by
  `receive` (`dest` + `dest_payload`), `spawn` (`dest`), and runtime
  bindings `_self`/`_parent`/`_msg`/`_payload`/`_msg_source`)
- `@N` — inject frame N (0-indexed) from the current context stack
- `@name` — inject contents of a named section (`@@section-name` ... `@@end`)
- `$$` — literal `$`; `@@` — literal `@`
- Resolved at operation time, not at frame push time
- Section content injected via `@name` is quoted (no `${name}` expansion)

## Runtime Bindings

The runtime provides every agent with identity bindings:

- `${_self}` — this agent's own mailbox ID. Always available.
- `${_parent}` — the spawning agent's mailbox ID. Only available for
  child agents created via `spawn` without `disown: true`. Root agents
  and disowned children do not have `_parent`.

These bindings persist across cycles (preserved on idle reset) and enable
symmetric communication: the parent has `${child_dest}` from `spawn`, the
child has `${_parent}` from the runtime. Disowned children must discover
peers through the blackboard or other shared services.

## Error Handling

```
LLM error → retry (×3) → exception mailbox → agent terminates
op error  → bind _op_error/_pending_ops → retry counter increments → LLM re-plans
cycle limit exceeded → exception mailbox → agent terminates
```

Three retries for LLM errors (schema violation, API error). After exhaustion,
the error is reported to the `"exception"` mailbox and the agent terminates.

Op execution errors (bad regex in `trap`, name collision in `spawn`) are
caught and recovered: the remaining ops are skipped, `${_op_error}` and
`${_pending_ops}` are bound with error details, and the retry counter
increments (so max-retries still protects against infinite error loops).
The LLM sees the error context on the next cycle and can re-plan.

A configurable cycle limit (`--max-cycles`, default 50) catches infinite loops.
Set to 0 for unlimited cycles. The limit is inherited by spawned children.
Transient API errors (429, 5xx) are retried with exponential backoff at the
HTTP layer before reaching the eval retry logic.

Service input validation: bash, watchdog, and pager services validate
LLM-generated payloads at their boundaries. Invalid inputs (non-integer
timeouts, malformed line numbers) fall back to defaults or return error
messages instead of crashing the service.

## Supervision Tree

```
Gizmo.Supervision (one_for_one)
├── Gizmo.Mailbox.Registry (Registry)
├── Gizmo.Services.Blackboard ("blackboard")
├── Gizmo.Services.Bash ("bash")
├── Gizmo.Services.Human ("human")
├── Gizmo.Services.HumanInput ("human_input")
├── Gizmo.Services.Exception ("exception")
├── Gizmo.Services.Reaper ("reaper")
├── Gizmo.Services.Watchdog ("watchdog")
├── Gizmo.Services.Pager ("pager")
├── Gizmo.Services.Batch ("batch")
├── Gizmo.Services.Eval ("eval")
├── Gizmo.FactorySupervisor (DynamicSupervisor)
│   ├── FactoryWorker (:temporary)
│   └── ...
├── Gizmo.Services.Factory ("factory")
├── Gizmo.Services.Migration ("migration")
└── Gizmo.AgentSupervisor (DynamicSupervisor)
    ├── Agent via Wrapper (:temporary)
    ├── Agent via Wrapper (:temporary)
    └── ...
```

- All services run under a single `one_for_one` supervisor (`Gizmo.Supervision`).
  If a service crashes, it is automatically restarted. Services are independent
  so one crash does not affect others.
- Agent processes run under `Gizmo.AgentSupervisor` (`DynamicSupervisor`) with
  `:temporary` restart — they are not restarted on exit. Restarting a crashed
  agent from its boot frame would duplicate work and confuse parent processes
  waiting for child messages. The watcher pattern (`Process.monitor`) notifies
  parents of child death via a `child_died:` message.
- `Gizmo.Agent.Wrapper` bridges `DynamicSupervisor` and the bare eval loop,
  using `:proc_lib.start_link/3` for proper OTP process initialization.

## Message Routing

```
┌──────────┐    send(mb_id, msg)    ┌───────────────┐
│  Agent   │ ──────────────────────→│ MailboxRouter  │
│ Process  │                        │  (Registry)    │
│          │←───────────────────────│               │
└──────────┘    message delivery    └───────┬───────┘
                                            │
                    ┌───────────────────────┬┴──────────────┐
                    │                       │               │
              ┌─────┴─────┐         ┌──────┴──┐    ┌──────┴──────┐
              │   bash    │         │  human  │    │ other agent │
              └───────────┘         └─────────┘    └─────────────┘
```

The router is an Elixir `Registry`. Each mailbox ID maps to an Elixir PID.
`send` is non-blocking message delivery. `receive` blocks the calling
process until a message arrives in its mailbox.

## Boot Frame

The boot frame is frame 0 on every agent's context stack. It is user-provided
content (task description, workflow steps, named sections). The runtime prompt
(syscall reference, well-known mailboxes, interpolation rules) is prepended
automatically by `Gizmo.Agent.runtime_prompt/0`.

By default, agents terminate when the context stack drains to `[]`. With
`--idle`, the boot frame is restored so the agent idles and can receive
new work. Agents return `frames: []` to finish (optionally after a `send`
to communicate results).

### Multi-file stacks

Multiple files can be loaded as frames:

- `gizmo task.txt` — frames=[task], boot_frame=task (backward compatible)
- `gizmo a.txt b.txt` — frames=[a, b], boot_frame=a
- `gizmo --boot sys.txt task.txt` — frames=[sys, task], boot_frame=sys
- `gizmo --each a.txt b.txt` — one independent agent per file
- `gizmo --each --boot sys.txt a.txt b.txt` — each agent gets [sys, file]

With `--boot`, the boot frame is separate from task frames. Without it, the
first positional file serves as both. This lets you reuse a generic boot
frame (with sections, idle behavior, etc.) across different task files.

With `--each`, each positional file becomes an independent agent instead of
being stacked into one. Combined with `--boot`, each agent gets the boot
frame as its first frame and the positional file as its second.

Different boot frames = different "OS distributions." Same kernel, different
preloaded services and instructions.

### Agent naming

By default, agents get auto-generated mailbox IDs like `agent_1`, `agent_2`.
The `--name <id>` CLI flag sets a custom mailbox ID for the root agent. In
spawn ops, `"name": "worker"` gives the child a custom ID. Names must be
unique — a duplicate name triggers op error recovery (`_op_error` is bound
and the LLM can retry with a different name).

Name collisions are recovered via the op error mechanism: `_op_error` is
bound with details and the LLM can re-plan on the next cycle.

Named agents are easier to address in boot frames, debug in logs, and
filter in traces.

## Message-Driven Eval Loop

By default, agents are **message-driven**: they sleep between eval cycles and
only wake when a message arrives in their mailbox. This avoids wasting LLM
calls on idle spinning.

- **First cycle**: Runs immediately with `${_msg} = "init"` and
  `${_msg_source} = "runtime"`. No actual message needed.
- **Subsequent cycles**: Block on `receive` for `{:mailbox_msg, ...}`.
  Content bound to `${_msg}`, source to `${_msg_source}`.
- **Grind mode** (`--grind` or `grind: true`): Opt-in hot loop. Agent cycles
  continuously without waiting for messages. Preserves the pre-Stage 12
  behavior for worker agents that need to churn.

## Grind and Idle: The Two Axes

`grind` and `idle` control two orthogonal aspects of agent behavior. **Grind**
controls cycle pacing: does the agent wait for a message between cycles
(message-driven, the default) or hot-loop continuously? **Idle** controls
frame-exhaust behavior: does the agent terminate when frames drain to `[]`
(the default) or restore the boot frame and wait for more work?

| | **terminate on exhaust** (default) | **idle on exhaust** (`--idle`) |
|---|---|---|
| **message-driven** (default) | One-shot / request-response. Agent wakes on message, does work, terminates when frames drain to `[]`. | Daemon. Agent wakes on message, does work, idles back to boot frame to wait for more. |
| **grind** (`--grind`) | Worker loop. Agent hot-loops with explicit `receive` ops, terminates when frames drain to `[]`. | Hot-loop daemon. Agent hot-loops, restores boot frame on exhaust. Bindings reset. Rare. |

Key invariants across the grid:

- **`_msg` binding:** Updated from the mailbox message each cycle in
  message-driven mode. Stays `"init"` in grind mode (only the first cycle
  gets the wake message).
- **Bindings accumulation:** Bindings from `receive`/`spawn` persist across
  cycles. On idle restore, bindings reset to `{_self, _parent}` only.
- **Trap availability:** Traps fire between cycles in message-driven mode
  only. In grind mode, there is no inter-cycle message check, so traps do
  not fire.
- **Performance:** Grind skips the inter-cycle mailbox wait, yielding ~2x
  faster cycle throughput. Message-driven mode pays one LLM roundtrip per
  message boundary.

## Trap (Interrupt Handler)

A single-slot interrupt handler registered via the `trap` op:

```json
{"op": "trap", "pattern": "^alert:", "frames": ["Handle alert: ${_interrupt}"]}
```

When a message matching the PCRE regex pattern arrives between cycles:
1. Handler frames are prepended to the context stack.
2. `${_interrupt}` and `${_interrupt_source}` are bound.
3. `${_msg}` and `${_msg_source}` are also bound as usual.

The trap persists across cycles — it fires again on the next matching
message. Only one trap can be active; a new `trap` replaces the old one.
Pass empty frames to clear it:

```json
{"op": "trap", "pattern": ".*", "frames": []}
```

This enables spawn simplification: a parent spawns a child, continues
sleeping, and naturally wakes when the child's message arrives. No
need to pair `spawn` + `receive` in the same op list.

## Watchdog Service

`Gizmo.Services.Watchdog` is a per-agent GenServer that sends periodic
`"tick"` messages (from source `"watchdog"`) to a target mailbox.
Started on demand via `--watchdog <ms>` or programmatically. Monitors the
target agent and stops when it dies.

Useful for agents that need periodic think-ticks without external stimulus.

## Technology

- **Language:** Elixir 1.19 / Erlang/OTP 28
- **Packaging:** Single `gizmo.exs` script file, run with `elixir gizmo.exs`
- **Dependencies:** `Req` (installed via `Mix.install/2` at script top)
- **JSON:** Req handles JSON encoding/decoding; Erlang `:json` for edge cases
- **Process model:** OTP process (`:proc_lib` via `Gizmo.Agent.Wrapper`) per agent, `DynamicSupervisor` for spawn
- **Message routing:** Elixir Registry
- **LLM backend:** Anthropic Claude and OpenAI-compatible APIs via Req
- **Human interface:** Initially IO, later Phoenix LiveView
