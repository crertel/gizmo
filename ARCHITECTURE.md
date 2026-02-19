# Gizmo Architecture

Gizmo is a minimal runtime for LLM agents modeled on process calculus and the
BEAM. An agent is a process with a context stack, a mailbox, and four syscalls.
Everything else—tool use, memory, multi-agent coordination, human
interaction—is built on top as mailbox-backed services.

## Key Principles

- **Eval is the loop, not an operation.** The runtime calls the LLM in a loop.
  The LLM is the rewrite rule; the context stack is the string being rewritten.
- **Four syscalls only.** `send`, `receive`, `fork`, `join`. No special-cased
  tool calling, memory, or orchestration primitives.
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
│  parent_id:     mb_id|nil   │  ← for join()
│                             │
│  eval loop:                 │
│    concat stack → LLM       │
│    LLM → {ops, frames}     │
│    execute ops              │
│    replace stack with frames│
│    repeat                   │
└─────────────────────────────┘
```

A process is **idle** when the context stack empties and the boot frame is
restored. The LLM re-evaluates the boot frame and typically issues a
`receive` to wait for new work.

## Syscalls

| Syscall | Signature | Behavior |
|---------|-----------|----------|
| `send`  | `send(mailbox_id, msg)` | Async fire-and-forget message to any mailbox. Non-blocking. |
| `receive` | `receive(dest)` | Block until a message arrives. Result stored in binding `dest` and messages queue. |
| `fork` | `fork(n, [frames...], dest)` | Spawn child with copied stack, pop top n frames, push new frames. Child mailbox ID stored in binding `dest`. |
| `join` | `join(msg)` | Send message to parent (or specified mailbox), then terminate self. |

All message content is interpolated (`${name}` from bindings) at operation
time.

## Well-Known Services

These are supervised processes with fixed mailbox names, registered at boot
by `Gizmo.Supervision`. They are not syscalls.

| Service | Mailbox | Purpose |
|---------|---------|---------|
| **blackboard** | `"blackboard"` | Key-value store. Shared memory. `{read, key}` / `{write, key, value}`. |
| **bash** | `"bash"` | Shell command execution. Send command string, get output back. |
| **human** | `"human"` | Terminal output. Send text to display to the user. |
| **human_input** | `"human_input"` | Terminal input. Send a prompt string, receive the user's typed response. |
| **exception** | `"exception"` | Error notification sink. Receives agent retry/cycle exhaustion reports. |

Per-agent state (not well-known, created per agent instance):

| Component | Scope | Purpose |
|-----------|-------|---------|
| **bindings** | in-process | Named bindings map. Values from `receive(dest)` and `fork(dest)`. Threaded through eval loop. |
| **messages queue** | per-agent | FIFO queue of `{content, source}` tuples. Each agent gets its own `MessagesQueue` GenServer. |

## Eval Loop Detail

```
1. Concatenate runtime prompt + all context stack frames → system prompt
2. Build user message: "Begin." + current bindings
3. Call LLM with system prompt and user message
4. LLM returns structured {ops, frames, notes} via eval_response tool
5. Interpolate frames and op strings against bindings and sections
6. Execute ops sequentially (may update bindings via receive/fork)
7. Replace context stack with returned frames
8. If stack is empty and boot frame exists → restore boot frame (idle)
9. Goto 1
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
    {"op": "send", "mailbox": "human", "msg": "I'll check the files."},
    {"op": "send", "mailbox": "bash", "msg": "ls -la"},
    {"op": "receive", "dest": "listing"}
  ],
  "frames": [
    "Process the directory listing in ${listing}."
  ],
  "notes": {"listing": "output of ls -la"}
}
```

Each op is an object with an `"op"` field and syscall-specific parameters:

| Op | Fields | Example |
|----|--------|---------|
| `send` | `mailbox`, `msg` | `{"op": "send", "mailbox": "bash", "msg": "ls"}` |
| `receive` | `dest` | `{"op": "receive", "dest": "output"}` |
| `fork` | `n`, `frames`, `dest` | `{"op": "fork", "n": 1, "frames": ["child task"], "dest": "child"}` |
| `join` | `msg` | `{"op": "join", "msg": "result"}` |

The schema is enforced by the LLM provider (Anthropic tool_use with forced
tool_choice, OpenAI structured outputs with json_schema). This eliminates
parsing ambiguity and the need for a text parser.

## Interpolation

- `${name}` — named binding resolved from bindings map (populated by
  `receive(dest)` and `fork(dest)`)
- `@N` — inject frame N (0-indexed) from the current context stack
- `@name` — inject contents of a named section (`@@section-name` ... `@@end`)
- `$$` — literal `$`; `@@` — literal `@`
- Resolved at operation time, not at frame push time
- Section content injected via `@name` is quoted (no `${name}` expansion)

## Error Handling

```
LLM error → retry (×3) → exception mailbox → agent terminates
cycle limit (50) exceeded → exception mailbox → agent terminates
```

Three retries for LLM errors (schema violation, API error). After exhaustion,
the error is reported to the `"exception"` mailbox and the agent terminates.
A separate cycle limit (50) catches infinite loops. Transient API errors
(429, 5xx) are retried with exponential backoff at the HTTP layer before
reaching the eval retry logic.

## Supervision Tree

```
Gizmo.Supervision (one_for_one)
├── Gizmo.Mailbox.Registry (Registry)
├── Gizmo.Services.Blackboard ("blackboard")
├── Gizmo.Services.Bash ("bash")
├── Gizmo.Services.Human ("human")
├── Gizmo.Services.HumanInput ("human_input")
├── Gizmo.Services.Exception ("exception")
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
  waiting for join messages. The watcher pattern (`Process.monitor`) notifies
  parents of child death.
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

When the context stack drains to `[]`, the boot frame is restored so the
agent idles and can receive new work. Agents that want to terminate use
`join`, which exits before the idle clause fires.

Different boot frames = different "OS distributions." Same kernel, different
preloaded services and instructions.

## Technology

- **Language:** Elixir 1.19 / Erlang/OTP 28
- **Packaging:** Single `gizmo.exs` script file, run with `elixir gizmo.exs`
- **Dependencies:** `Req` (installed via `Mix.install/2` at script top)
- **JSON:** Req handles JSON encoding/decoding; Erlang `:json` for edge cases
- **Process model:** OTP process (`:proc_lib` via `Gizmo.Agent.Wrapper`) per agent, `DynamicSupervisor` for fork
- **Message routing:** Elixir Registry
- **LLM backend:** Claude API via Req
- **Human interface:** Initially IO, later Phoenix LiveView
