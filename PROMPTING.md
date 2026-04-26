# Writing Boot Prompts for Gizmo

This guide explains how to write boot frame files for Gizmo agents. A boot
frame is plain text that becomes part of the agent's system prompt. The runtime
calls the LLM, executes returned ops, replaces the frame stack, and repeats.

> [!IMPORTANT]
> Current Gizmo has three ops only: `send`, `spawn`, `trap`.
> The runtime is message-driven only. If you need a later wakeup, use an
> explicit message source such as `${_self}` or `watchdog`.

## Quick Start

Generate a starter boot frame:

```bash
elixir gizmo.exs --init my_task.txt
```

Run it:

```bash
elixir gizmo.exs my_task.txt
elixir gizmo.exs -v my_task.txt
elixir gizmo.exs -vvv my_task.txt
elixir gizmo.exs --thinking my_task.txt
```

## Boot Frame Structure

A boot frame contains task-specific instructions only. Gizmo automatically
prepends its runtime preamble, which documents the eval contract, mailboxes,
interpolation, and bindings.

Child processes created with `spawn` also get the runtime preamble
automatically. Child frames should therefore describe task logic, not the
runtime itself.

## The Eval Loop

```text
1. The runtime builds the system prompt from the runtime preamble + frame stack.
2. The runtime sends a user message containing current bindings.
3. The LLM returns ops, frames, and notes.
4. Interpolation runs before ops execute.
5. Ops execute sequentially.
6. Returned frames replace the current stack.
7. If frames is []:
   - default: terminate
   - with --idle: restore the boot frame and wait for another message
8. Otherwise, wait for the next mailbox wakeup and repeat.
```

**Key timing rule:** interpolation happens before the current cycle's ops run.
If you send to `bash` now, the result is not available until the next wakeup as
`${_msg}`.

## Interpolation Reference

### `${name}` — named bindings

Important built-in bindings:

- `${_msg}` — text summary of the message that woke this cycle
- `${_payload}` — full JSON encoding of that message
- `${_msg_source}` — sender mailbox ID
- `${_self}` — this agent's mailbox ID
- `${_parent}` — parent agent mailbox ID, for non-disowned children
- `${_interrupt}` / `${_interrupt_source}` — trap match details

`spawn` also adds a binding using its `dest` field.

### `$$` — literal dollar sign

`"Price: $$5"` becomes `"Price: $5"`.

### `@N` — frame references

Inject frame `N` from the current context stack. Useful for loops like `["@0"]`.

### `@name` — named section references

Inject the contents of a section defined as:

```text
@@worker
...
@@end
```

### `@@` — literal at sign

`"user@@host"` becomes `"user@host"`.

## Core Patterns

### One-shot agent

Do the work, then return empty frames.

```text
You are a one-shot greeter. Send a hello to 'human', then terminate.
```

### Continuation frame

Send a request now, handle the response on the next cycle.

```text
You are a system inspector. Messages arrive as ${_msg}.

@@step2
The output of 'uname -a' arrived as ${_msg}.
Send {"text": "System info: ${_msg}"} to 'human'.
Return frames: [].
@@end

1. Send {"command": "uname -a"} to 'bash'.
2. Return frames: ["@step2"].
```

### Loops with `@0`

Use `["@0"]` only for the repeating part. If setup instructions live in the
same frame, `@0` will replay them every cycle.

### Loops with named sections

Separate first-cycle setup from the steady-state loop.

```text
You are an echo bot. Messages arrive as ${_msg}.

@@loop
If ${_msg} is "quit":
  Send {"text": "goodbye"} to 'human'.
  Return frames: [].
Otherwise:
  Send {"prompt": "you said: ${_msg}\n> "} to 'human_input'.
  Return frames: ["@loop"].
@@end

1. Send {"prompt": "> "} to 'human_input'.
2. Return frames: ["@loop"].
```

### Spawn with named sections

Children do not inherit the parent's whole section namespace. If you spawn
`["@worker"]`, the child gets the resolved text of `@worker`, not every other
section from the parent.

```text
@@worker
Send {"command": "date +%s"} to 'bash'.
Return frames: ["The bash result arrived as ${_msg}. Send it to ${_parent}. Return frames: []."].
@@end

@@done
The child replied as ${_msg}. Send it to 'human'. Return frames: [].
@@end

1. Spawn a child with frames: ["@worker"], dest "child".
2. Register a trap for "^child_died:".
3. Return frames: ["@done"].
```

### Disowned peers with blackboard discovery

Use `"disown": true` when you want independent peers instead of parent/child
workflow coupling.

```text
You are a coordinator. Spawn independent bank and store peers. Messages arrive
as ${_msg}.

@@bank
If ${_msg} is "init":
  Send {"action": "write", "key": "bank_mb", "value": "${_self}"} to 'blackboard'.
  Return frames: ["@bank"].

If ${_msg} contains "balance_request":
  Parse ${_payload}, extract "reply_to", and send {"text": "balance:42"} there.
  Return frames: ["@bank"].

Otherwise: return frames: ["@bank"].
@@end

@@wait-result
If ${_msg} starts with "balance:":
  Send {"text": "Result: ${_msg}"} to 'human'.
  Return frames: [].
Otherwise:
  Return frames: ["@wait-result"].
@@end

1. Spawn a child with frames: ["@bank"], dest "bank_id", "disown": true, "idle": true, "name": "bank".
2. Return frames: ["@wait-result"].
```

### Idle workers

`idle` means: when frames drain to `[]`, restore the boot frame and wait for
another message. This is the right pattern for long-lived children.

```json
{"op": "spawn", "frames": ["@worker"], "dest": "child", "idle": true}
```

### Watchdog wakes

Use `watchdog` for time-based wakeups.

```json
{"op": "send", "mailbox": "watchdog", "msg": {"action": "every", "ms": 5000}}
```

On later cycles the agent wakes with `${_msg} = "tick"` and
`${_msg_source} = "watchdog"`.

### Context stack peeling

For known multi-step workflows, return a queue of frames and peel one per
cycle.

```text
@@step-a
The bash result arrived as ${_msg}. Save it to blackboard.
Return the remaining context stack.
@@end

@@step-b
The blackboard confirmed: ${_msg}. Read the saved result back.
Return frames: [].
@@end

1. Send {"command": "uname -a"} to 'bash'.
2. Return frames: ["@step-a", "@step-b"].
```

### Fire-and-forget children

Use a disowned child for side effects you do not want mixed into the parent's
message flow.

```json
{"op": "spawn",
 "frames": ["Send {\"command\": \"wall 'status update'\"} to 'bash'. Return frames: []."],
 "dest": "_w",
 "disown": true}
```

If the parent itself is idle and you want the child to terminate rather than
idle, set `"idle": false` explicitly.

### Batch recon

Use `batch` when you need multiple facts before reasoning.

```json
{"op": "send", "mailbox": "batch", "msg": {"requests": [
  {"mailbox": "bash", "msg": {"command": "uname -a"}},
  {"mailbox": "bash", "msg": {"command": "whoami"}},
  {"mailbox": "bash", "msg": {"command": "df -h /"}}
]}}
```

### Factory retry loop

Factory creation often needs 1-2 retries. Keep deploy logic in a self-looping
section.

```text
@@deploy
If ${_msg} starts with "error:":
  Fix the code, resend create, return ["@deploy"].
Otherwise:
  Proceed to the next step.
@@end
```

## Common Pitfalls

### 1. Using `${_msg}` for a response that has not arrived yet

Wrong:

```json
{
  "ops": [
    {"op": "send", "mailbox": "bash", "msg": {"command": "uname -a"}},
    {"op": "send", "mailbox": "human", "msg": {"text": "Result: ${_msg}"}}
  ],
  "frames": [],
  "notes": {}
}
```

Right: send now, use `${_msg}` in the continuation frame next cycle.

### 2. Continuation frames that are too terse

`frames: ["step2"]` is not a useful prompt. Write a real next-step
instruction.

### 3. `@0` replaying one-time setup

Keep setup and steady-state logic in separate sections.

### 4. Section names colliding with frame indices

Do not name sections `@@0`, `@@1`, and so on.

### 5. Embedding `@name` references inside long continuation prose

Use section references as standalone entries like `["@step2"]`, not buried
inside larger text.

### 6. Child agents returning parent-only section references

Children only know the resolved frames they were spawned with. If a child needs
multiple phases, put those phases inside the child's own frame text.

### 7. Boot-frame instructions re-executing on every cycle

The boot frame remains visible. Put first-cycle-only instructions in named
sections or make later frames clearly override them.

### 8. Transitioning without sending anything

In the message-driven model, a section that sends nothing and waits for some
future cycle will hang forever unless some other process wakes it.

### 9. Overpacking a cycle

Do one logical step per cycle. Send a request now, handle its result later.

## Mailbox Protocols

### `human`

```json
{"op": "send", "mailbox": "human", "msg": {"text": "Hello, user!"}}
```

### `human_input`

```json
{"op": "send", "mailbox": "human_input", "msg": {"prompt": "Enter your name: "}}
```

The user's line arrives as `${_msg}` next cycle.

### `bash`

```json
{"op": "send", "mailbox": "bash", "msg": {"command": "uname -a"}}
```

Optional fields: `"timeout"`, `"mode"`, `"note"`.

### `blackboard`

- write: `{"action": "write", "key": "...", "value": "..."}`
- read: `{"action": "read", "key": "..."}`

### `watchdog`

- `{"action": "every", "ms": N}`
- `{"action": "after", "ms": N}`
- `{"action": "cancel"}`
- `{"action": "list"}`

### `batch`

Send one request containing many sub-requests and process the bundled result on
the next cycle.

### `eval`

Evaluate allowlisted Elixir expressions for math and data transformation.

### `factory`

Create and destroy stateful custom services at runtime.

## CLI Flags

| Flag | Effect |
|------|--------|
| `-v` | Lifecycle events, cycle headers, frames summary |
| `-vv` | + ops per cycle (`send`, `spawn`, `trap`) |
| `-vvv` | + bindings, full frame content |
| `--thinking` | Enable extended thinking (Anthropic only) |
| `--model <id>` | Choose LLM model |
| `--test` | Run built-in smoke tests |
| `--init <file>` | Generate a starter boot frame |
| `--max-cycles N` | Max eval cycles before terminating |
| `--idle` | Restore the boot frame on exhaust instead of terminating |
| `--boot <file>` | Separate boot frame file |
| `--watchdog <ms>` | Schedule periodic watchdog ticks for the root agent |
| `--log-timings` | Show timing data per cycle |
| `--log-full-prompts` | Show full prompt content |
| `--runtime <file>` | Use custom runtime preamble |
| `--name <id>` | Custom mailbox ID for root agent |
| `--each` | Spawn one agent per positional file |
| `--dump-runtime <file>` | Write built-in runtime preamble to a file |
| `--dry-run` | Print the full initial prompt and exit |
| `--list-models` | List available models |
| `--trace` | Emit NDJSON trace to stderr |
| `--trace-file <file>` | Emit NDJSON trace to a file |
| `--trace-service` | Include service events in the trace |
| `--trace-messages` | Include message routing events in the trace |
| `--bash-timeout N` | Default bash timeout in ms |
| `--node <name>` | Start Erlang distribution |
| `--cookie <cookie>` | Set Erlang distribution cookie |
| `--accept-migration` | Start in migration-accept mode |

## Design Summary

The prompt discipline is simple:

- think in mailbox wakeups, not hidden blocking
- send requests now
- use continuation frames
- use `${_msg}` on the next cycle
- use `idle` for long-lived workers
- use `watchdog` for timed wakes
- use `trap` for asynchronous interruptions
