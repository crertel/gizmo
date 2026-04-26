# Gizmo Architecture

Gizmo is a minimal runtime for LLM agents modeled on process calculus and the
BEAM. An agent is a process with a context stack, a mailbox, and three ops:
`send`, `spawn`, and `trap`. Everything else, including tool use, memory,
timers, and multi-agent coordination, is implemented as mailbox-backed
services.

## Key Principles

- **Eval is the loop, not an operation.** The runtime calls the LLM in a loop.
- **Three ops only.** `send`, `spawn`, `trap`.
- **Everything is a mailbox.** Bash, a key-value store, a human, another
  agent: same message interface.
- **The context stack is the prompt.** Frames are concatenated into the system
  prompt. The boot frame remains the stable prefix for prompt caching.

## Process Model

```text
┌─────────────────────────────┐
│         Agent Process       │
│  (plain process via         │
│   :proc_lib / Wrapper)      │
│                             │
│  context_stack: [frame]     │  ← prompt, bottom-up
│  mailbox_id:    mb_id       │  ← receiving address
│  parent_id:     mb_id|nil   │  ← ${_parent} binding
│  trap:          {regex, frames}|nil
│                             │
│  eval loop:                 │
│    wait for mailbox message │
│    check trap               │
│    build prompt             │
│    LLM → {ops, frames}      │
│    execute ops              │
│    replace stack            │
│    repeat                   │
└─────────────────────────────┘
```

Agents are ephemeral by default. After every eval cycle, a gremlin dies unless
that cycle sent a message to the `keep_alive` mailbox. If a renewed cycle
returns `frames: []`, the runtime injects a synthetic `stack_exhausted`
message at the front of the mailbox queue so traps can rebuild work.

## Ops

| Op | JSON format | Behavior |
|----|-------------|----------|
| `send` | `{"op": "send", "mailbox": "...", "msg": {...}}` | Async message delivery to any mailbox. `msg` is always a JSON object. |
| `spawn` | `{"op": "spawn", "frames": [...], "dest": "..."}` | Create a child process. Store the child's mailbox ID in binding `dest`. Optional fields: `disown`, `name`, `model`. |
| `trap` | `{"op": "trap", "pattern": "...", "frames": [...]}` | Register an interrupt handler. On match, handler frames are prepended to the stack. Empty frames clear the trap. |

Interpolation applies to op payloads and returned frames before ops execute.

## Well-Known Services

These are supervised processes with fixed mailbox names. They are ordinary
mailbox endpoints, not special opcodes.

| Service | Mailbox | Purpose |
|---------|---------|---------|
| `blackboard` | `"blackboard"` | Key-value store. |
| `bash` | `"bash"` | Shell command execution with optional timeout/mode. |
| `keep_alive` | `"keep_alive"` | Per-turn lease renewal. Payload ignored. |
| `human` | `"human"` | Terminal output. |
| `human_input` | `"human_input"` | Terminal input. |
| `exception` | `"exception"` | Error notification sink. |
| `reaper` | `"reaper"` | Kill descendant agents. |
| `watchdog` | `"watchdog"` | Timer service: `every`, `after`, `cancel`, `list`. |
| `pager` | `"pager"` | Document pager with per-document sessions. |
| `batch` | `"batch"` | Parallel fan-out and result collection. |
| `eval` | `"eval"` | Sandboxed Elixir expression evaluation. |
| `factory` | `"factory"` | Runtime creation of custom stateful services. |
| `migration` | `"migration"` | Live runtime migration. |

Per-agent runtime state:

| Component | Scope | Purpose |
|-----------|-------|---------|
| `bindings` | in-process | Named values such as `${_self}`, `${_parent}`, `${_msg}`, `${_payload}`, `${_msg_source}`, spawn `dest` bindings, and error recovery bindings. |
| `messages queue` | per-agent | Retained support module for tests and migration bookkeeping. Not part of the live eval path. |

## Eval Loop

```text
1. Wait for a mailbox message.
   - First cycle is synthetic: _msg="init", _msg_source="runtime"
   - Later cycles wake on {:mailbox_msg, ...}
   - If a trap matches, prepend handler frames and bind _interrupt
2. Concatenate runtime preamble + context stack → system prompt
3. Build user message from current bindings
4. Call LLM
5. LLM returns {ops, frames, notes}
6. Interpolate returned frames and op payloads
7. Execute ops sequentially
8. Replace context stack with returned frames
9. If the cycle did not send to `keep_alive`, terminate
10. If the cycle did send to `keep_alive` and stack is empty:
    - enqueue `{"text":"stack_exhausted","type":"stack_exhausted"}` at mailbox front
11. Repeat
```

The stack is self-reducing:

- `frames: []` means the current stack is exhausted.
- One returned frame is a continuation.
- Multiple returned frames represent queued future work.

## LLM Output Format

The LLM returns structured JSON via the forced `eval_response` tool:

```json
{
  "ops": [
    {"op": "send", "mailbox": "human", "msg": {"text": "I'll check the files."}},
    {"op": "send", "mailbox": "bash", "msg": {"command": "ls -la"}}
  ],
  "frames": [
    "The directory listing arrived as ${_msg}. Summarize it for the human."
  ],
  "notes": {"_plan": "inspect the working directory"}
}
```

## Interpolation

- `${name}`: named bindings from the runtime or previous cycles
- `@N`: inject frame `N` from the current context stack
- `@name`: inject a named section (`@@name` ... `@@end`)
- `$$`: literal `$`
- `@@`: literal `@`

Important consequence: interpolation happens before the current cycle's ops
run. If you need a service response, send the request now and return a
continuation frame that handles `${_msg}` on the next cycle.

## Runtime Bindings

- `${_self}`: this agent's mailbox ID
- `${_parent}`: parent mailbox ID for non-disowned children
- `${_msg}`: text summary of the message that woke this cycle
- `${_payload}`: full JSON payload of that message
- `${_msg_source}`: sender mailbox ID
- `${_interrupt}` / `${_interrupt_source}`: trap match details
- `${_op_error}` / `${_pending_ops}`: op recovery metadata

Spawn adds one more binding: the child mailbox ID is stored under the op's
`dest` name.

## Message-Driven Model

Gizmo now has one execution model only: message-driven wakeups.

- First cycle runs immediately with synthetic `init`.
- Subsequent cycles run only when a mailbox message arrives.
- Time-based wakeups are explicit service messages, typically from
  `watchdog`.
- Autonomous continuation is explicit: self-send or watchdog scheduling.

## Lease Renewal

Long-lived workers are explicit rather than mode-driven.

- If a cycle omits `keep_alive`, the gremlin dies after that turn.
- If a cycle sends `keep_alive` and returns non-empty `frames`, it survives and
  waits for a normal mailbox wakeup.
- If a cycle sends `keep_alive` and returns `frames: []`, the runtime injects
  `stack_exhausted` at the front of the mailbox queue so a trap can rebuild
  work.

## Trap

Trap is a single-slot interrupt handler:

```json
{"op": "trap", "pattern": "^alert:", "frames": ["Handle ${_interrupt}"]}
```

When a matching message arrives between cycles:

1. handler frames are prepended to the stack
2. `${_interrupt}` and `${_interrupt_source}` are bound
3. `${_msg}` and `${_msg_source}` are also bound normally

Clear a trap by returning:

```json
{"op": "trap", "pattern": ".*", "frames": []}
```

## Boot Frame and Multi-File Stacks

- `gizmo task.txt` → `task.txt` is both boot frame and task frame
- `gizmo a.txt b.txt` → stacked frames, `a.txt` is boot frame
- `gizmo --boot sys.txt task.txt` → `sys.txt` is boot frame, `task.txt` is stacked on top
- `gizmo --each a.txt b.txt` → one independent agent per file

The boot frame is just the initial stack and a convenient place to define named
sections. Persistence is handled by `keep_alive`, not by restoring boot frames
implicitly.

## Agent Naming

- Root agent: `--name <id>`
- Child agent: `"name": "worker"` on `spawn`

Name collisions are recovered as op errors via `${_op_error}`.

## Error Handling

- LLM errors: retry up to 3 times, then report to `exception`
- Op errors: bind `${_op_error}` and `${_pending_ops}`, skip remaining ops, let the LLM re-plan next cycle
- Cycle limit: `--max-cycles N`, with `0` meaning unlimited

## Supervision Tree

```text
Gizmo.Supervision
├── Registry
├── blackboard
├── bash
├── human
├── human_input
├── exception
├── reaper
├── watchdog
├── pager
├── batch
├── eval
├── factory supervisor + factory
├── migration
└── agent supervisor
```

Services are restarted if they crash. Agents are `:temporary` children and are
not restarted.

## Technology

- Elixir 1.19 / OTP 28
- Single-file `gizmo.exs`
- `Req` for HTTP and LLM transport
- Anthropic and OpenAI-compatible backends
- Registry-based mailbox routing
