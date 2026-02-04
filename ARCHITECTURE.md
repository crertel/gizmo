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
│  (Elixir GenServer)         │
│                             │
│  context_stack: [frame]     │  ← the prompt, bottom-up
│  mailbox_id:    mb_id       │  ← address for receiving messages
│  parent_id:     mb_id|nil   │  ← for join()
│                             │
│  eval loop:                 │
│    pop top frame            │
│    concat remaining → LLM   │
│    parse <ops> + <frames>   │
│    execute ops              │
│    push replacement frames  │
│    repeat                   │
└─────────────────────────────┘
```

A process is **idle** when only the boot frame remains. The boot frame is a
self-replacing frame that checks the mailbox for new work.

## Syscalls

| Syscall | Signature | Behavior |
|---------|-----------|----------|
| `send`  | `send(mailbox_id, msg)` | Async fire-and-forget message to any mailbox. Non-blocking. |
| `receive` | `receive()` | Block until a message arrives. Result goes to messages queue and args stack. |
| `fork` | `fork(n, [frames...])` | Spawn child with copied stack, pop top n frames, push new frames. Child mailbox ID pushed to parent's args. |
| `join` | `join(msg)` | Send message to parent (or specified mailbox), then terminate self. |

All message content is interpolated (`$n` from args, `${name}` from
blackboard) at operation time.

## Well-Known Services

These are ordinary processes registered at boot. They are not syscalls.

| Service | Mailbox | Purpose |
|---------|---------|---------|
| **args** | registered | Argument stack. Data values for `$n` interpolation. Auto-pushed by `receive()`. |
| **messages** | registered | Message queue. `receive()` results with content + source metadata. |
| **blackboard** | registered | Key-value store. Persistent shared memory. `{read, key}` / `{write, key, value}`. |
| **bash** | registered | Shell command execution. Send command string, get output back. |
| **human** | registered | User interaction bridge. IO or Phoenix channel behind the mailbox. |
| **supervisor** | registered | Error escalation and process replacement. |

## Eval Loop Detail

```
1. Pop top frame from context stack
2. Concatenate remaining stack bottom-up (boot frame first)
3. Call LLM: remaining stack = prefix, popped frame = final input
4. Parse response for <ops> and <frames> blocks
5. Execute ops sequentially
6. Push replacement frames (last listed = top of stack)
7. If only boot frame remains → boot frame self-replaces (idle)
8. Goto 1
```

The stack is **self-reducing**:
- 0 replacement frames → stack shrinks (work done)
- 1 replacement frame → continuation
- N replacement frames → task decomposition

## LLM Output Format

The LLM emits `<ops>` and `<frames>` blocks. Prose outside these blocks is
logged or forwarded to human.

```
I need to check the files.

<ops>
send(bash, "ls -la")
receive()
</ops>

<frames>
Process the directory listing.
</frames>
```

Frames are separated by `---`. No JSON tool calling—ops are native text.

## Interpolation

- `$n` — positional reference to args stack (1-indexed from bottom)
- `${name}` — named reference resolved via blackboard
- Resolved at operation time, not at frame push time

## Error Handling

```
parse failure → retry (x2) → exception mailbox → next frame tries → ... → supervisor
```

Three retries for unparseable LLM output. After that, the malformed output
goes to an exception mailbox. Subsequent frames inherit exception context and
can attempt recovery. Unrecoverable errors escalate to the supervisor.

## Supervision Tree

```
Application
├── MailboxRouter (Registry)
├── ServiceSupervisor (one_for_one)
│   ├── BashAdapter
│   ├── ArgsStack
│   ├── MessagesQueue
│   ├── Blackboard
│   ├── HumanAdapter
│   └── Supervisor (error escalation)
└── AgentSupervisor (DynamicSupervisor)
    ├── Agent Process 1
    ├── Agent Process 2
    └── ...
```

- Service processes run under a static `one_for_one` supervisor.
- Agent processes (spawned by `fork`) run under a `DynamicSupervisor`.
- `Process.monitor` links parent to child for unexpected death notification.

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
GenServer until a message arrives in its mailbox.

## Boot Frame

The boot frame is frame 0 on every process's context stack. It contains:
- The syscall descriptions
- The mailbox registry (available services and their addresses)
- Instructions for idle behavior (check mailbox, self-replace)

Different boot frames = different "OS distributions." Same kernel, different
preloaded services and instructions.

## Technology

- **Language:** Elixir 1.19 / Erlang/OTP 28
- **Packaging:** Single `gizmo.exs` script file, run with `elixir gizmo.exs`
- **Dependencies:** `Req` (installed via `Mix.install/2` at script top)
- **JSON:** Erlang/OTP built-in `:json` module (no external JSON library)
- **Process model:** OTP GenServer per agent, DynamicSupervisor for fork
- **Message routing:** Elixir Registry
- **LLM backend:** Claude API via Req
- **Human interface:** Initially IO, later Phoenix LiveView
