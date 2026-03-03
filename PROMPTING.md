# Writing Boot Prompts for Gizmo

This guide explains how to write boot frame files for Gizmo agents. A boot
frame is a plain text file that becomes the agent's system prompt. The agent
reads it, decides what ops to run and what frames to return, and the runtime
executes a loop: prompt the LLM, run ops, replace the context stack with the
returned frames, repeat.

## Quick start

Generate a starter boot frame:

```
elixir gizmo.exs --init my_task.txt
```

Edit the `## Your task` section, then run:

```
elixir gizmo.exs my_task.txt
elixir gizmo.exs -v my_task.txt        # verbose (lifecycle, cycle headers, frames)
elixir gizmo.exs -vvv my_task.txt      # max verbosity (+ ops, bindings)
elixir gizmo.exs --thinking my_task.txt # enable extended thinking
```

## Boot frame structure

A boot frame is just your task-specific instructions. The runtime automatically
appends a **runtime preamble** below every agent's system prompt that teaches
the LLM how the runtime works (eval_response contract, syscalls, interpolation
syntax, well-known mailboxes, timing rules). You don't need to include any of
that in your boot frame.

This also means **child processes** created via `spawn` automatically get the
runtime preamble — you only need to provide task instructions in child frames.

The `--init` flag generates a starter template with a placeholder task section.

## The eval loop

Understanding the eval loop is critical for writing good prompts.

```
1. The context stack (list of frame strings) becomes the system prompt.
   Multiple frames are joined with "\n\n---\n\n".
   The runtime preamble is appended automatically after the frames.
2. The LLM is called with this system prompt.
3. The LLM returns: ops (operations to execute), frames (new context stack),
   and notes (annotations for bindings).
4. Interpolation runs on the returned ops and frames BEFORE ops execute.
5. Ops execute sequentially (send, receive, spawn, trap).
6. The returned frames become the new context stack.
7. If frames is empty []:
   - Default: the agent terminates.
   - With `--idle`: the boot frame is restored and the agent idles.
8. Otherwise, go to 1.
```

**Key timing rule:** Interpolation happens *before* ops run, using bindings
from the previous cycle. In message-driven mode, `${_msg}` is bound *before*
the cycle starts (from the mailbox message that woke the agent), so it is
always available for interpolation. If you send to `bash` and need the result,
return a continuation frame — the bash output will arrive as `${_msg}` on the
next cycle and be interpolated into that cycle's ops and frames.

## Interpolation reference

All interpolation applies to the ops and frames the LLM returns. It does
**not** apply to the system prompt the LLM sees — the LLM sees raw text
including `${name}`, `@0`, section markers, etc.

### `${name}` — named bindings

The bindings map holds values from the runtime and ops. The most important
bindings are set automatically by the message-driven model:

- `${_msg}` — the text summary of the message that woke this cycle
- `${_payload}` — the full JSON encoding of the message that woke this cycle
- `${_msg_source}` — the sender's mailbox ID
- `${_self}` — this agent's mailbox ID
- `${_parent}` — the parent agent's mailbox ID (spawned children only)

The `spawn` op creates bindings via its `dest` field. The `receive` op
creates two bindings: `${dest}` (text summary) and `${dest_payload}`
(full JSON), mirroring `_msg` / `_payload`.

```
# Agent sent {"command": "uname -a"} to bash last cycle. Bash response woke this cycle.
# Bindings show: ${_msg} = Linux hostname 6.18... , ${_msg_source} = bash
# The LLM returns:
  ops:    [send("human", {"text": "System info: ${_msg}"})]
  frames: []
  notes:  {}

# After interpolation:
  ops:    [send("human", {"text": "System info: Linux hostname 6.18..."})]
```

Unresolved binding refs are left as-is. If there's no binding named "foo",
`${foo}` stays as the literal string `${foo}`.

### `$$` — literal dollar sign

Use `$$` anywhere you need a literal `$` in output that won't be interpreted
as an interpolation reference.

```
  "Price: $$5"     → "Price: $5"
  "Escape: $$$$"   → "Escape: $$"
```

### `@N` — frame references

Inject the full text of frame N (0-indexed) from the current context stack.
The injected text is **quoted verbatim** — any `$` in the frame content is
escaped so it won't be interpolated.

```
# Context stack: ["frame zero content", "frame one content"]
# LLM returns:
  frames: ["@0"]

# After interpolation:
  frames: ["frame zero content"]
```

This is most useful for **loops** — the agent can return `["@0"]` to replay
its current frame without the LLM having to reproduce the entire prompt.

### `@name` — named section references

Inject the content of a named section defined elsewhere in the context stack.
Like `@N`, the injected text is quoted verbatim.

```
# The current frame contains:
#   @@greeting
#   Hello, welcome to the system!
#   @@end

# LLM returns:
  ops: [send("human", {"text": "@greeting"})]

# After interpolation:
  ops: [send("human", {"text": "Hello, welcome to the system!"})]
```

Section names must match `[a-zA-Z0-9_-]+`. If no section with that name
exists, the `@name` reference is left as-is.

### `@@` — literal at sign

Use `@@` anywhere you need a literal `@` in output.

```
  "email: user@@host.com" → "email: user@host.com"
```

### Named sections: `@@name` / `@@end`

Define named regions in your frame text:

```
@@section-name
content goes here
multiple lines are fine
@@end
```

Rules:

- `@@section-name` must appear at the start of a line, followed by a newline.
- `@@end` must appear at the start of a line.
- The content between the markers is extracted (markers themselves excluded).
- Sections are scanned across all frames in the context stack, in order.
  **First match wins** — if two frames define `@@worker`, only the first is
  used.
- Section markers are **left in** the system prompt the LLM sees. This is
  intentional: the LLM can see and reason about section boundaries.
- **Sections persist across cycles.** Once a section is defined in any frame,
  it remains available on subsequent cycles even if the defining frame is
  replaced. New sections from later frames merge in; if a section is
  redefined, the newest definition wins.
- Section names share a namespace with frame numbers. If you have a section
  named `"0"`, it will be shadowed by the frame reference for frame 0.

### Resolution order

Interpolation resolves in this order:

1. `@@` → escape sentinel (so `@@end` markers aren't confused with `@end` refs)
2. `$$` → escape sentinel
3. `@name` / `@N` → inject section content (with `$` in content escaped)
4. `${name}` → named bindings
5. Restore escape sentinels to literal `@` and `$`

The key consequence: section content is injected *before* `$` interpolation,
but all `$` characters in the injected content are escaped. So `${name}` inside
a section stays as literal `${name}` in the output — it won't be resolved
against the bindings. This is the "quoted verbatim" guarantee.

## Patterns

### One-shot agent

The simplest pattern. Do something, return empty frames. The agent
terminates cleanly when frames drain to `[]`.

```bash
elixir gizmo.exs hello.txt
```

```
You are a one-shot greeter. Send a short hello to the 'human' mailbox,
then terminate by returning an empty frames array.
```

The LLM returns:

```json
{
  "ops": [{"op": "send", "mailbox": "human", "msg": {"text": "Hello!"}}],
  "frames": [],
  "notes": {}
}
```

One cycle, then done.

### Multi-step with continuation frames

When a task spans multiple eval cycles, the LLM must return **continuation
frames** that tell its future self what to do next. These frames replace
the context stack entirely — the original boot frame is gone.

```
You are a system inspector. Messages arrive as ${_msg} between cycles.
This is the first cycle (${_msg} is "init").

@@step2
The output of 'uname -a' arrived as ${_msg}.
Send a message to 'human' that says: "System info: ${_msg}"
Then terminate with an empty frames array [].
@@end

1. Send the command "uname -a" to the 'bash' mailbox.
2. Return frames: ["@step2"] to continue to the next step.
Do NOT issue a receive op — the bash output arrives as ${_msg} next cycle.
```

Cycle 1 (`${_msg} = "init"`): LLM sends the bash command, returns
`["@step2"]` as a continuation frame.

Cycle 2 (`${_msg}` = bash output): LLM sends it to human, returns `[]`.

**Tip:** Tell the LLM to write *real prompts* as continuation frames, not
shorthand labels. A frame like `"step2"` gives the LLM nothing to work with
on the next cycle. A frame like `"The bash result arrived as ${_msg}. Send
'System info: ${_msg}' to human, then return empty frames to terminate."`
is much better.

### Loops with `@0`

For agents that repeat the same behavior, use `@0` to replay the current
frame without the LLM having to reproduce it.

**Pitfall:** If the frame contains one-time setup instructions (like "greet
the user"), using `@0` will replay those instructions every cycle. Separate
setup from loop body using named sections instead (see below).

### Loops with named sections

Define the loop body as a `@@section` and have the setup frame hand off to
it after first-time initialization.

```
You are an interactive echo-bot. This is the first cycle (setup).
Messages arrive between cycles as ${_msg}. Do NOT issue receive ops.

@@quit
The user typed "quit". Send {"text": "echo-bot: goodbye!"} to 'human'.
Return frames: [] to terminate.
@@end

@@loop
The user's most recent input arrived as ${_msg}. Decide what to do:

- If ${_msg} is "quit": return frames ["@quit"] with no ops.
- Otherwise: send {"prompt": "echo-bot: you said: ${_msg}\necho-bot> "}
  to 'human_input'. Return frames: ["@loop"].
@@end

First-time setup:
1. Send a greeting to 'human'.
2. Send {"prompt": "echo-bot> "} to 'human_input'.
3. Return frames: ["@loop"] to enter the loop.

After this first cycle, the @loop section takes over for all subsequent
iterations. You will NOT see this setup frame again.
```

Cycle 1 (`${_msg} = "init"`): LLM greets, sends prompt to human_input.
Returns `["@loop"]`. After interpolation, the context stack becomes the
loop body text.

Cycle 2+ (loop body, `${_msg}` = user's typed input): LLM echoes or quits.
Returns `["@loop"]` to keep going, or `["@quit"]` then `[]` to stop.

This pattern cleanly separates one-time setup from the repeating loop.

### Spawn with named sections as child prompts

When spawning a child process, the child doesn't inherit the parent's context
stack — it gets its own frames. Define the child's task as a named section
in the parent's frame, and reference it with `@worker` in the spawn frames.

```
You are a supervisor that delegates work to a child process.
Messages arrive between cycles as ${_msg}. This is the first cycle.

@@worker
Send the command 'date +%s' to 'bash'. Return a continuation frame that
says: "The bash output arrived as ${_msg}. Send 'timestamp: ${_msg}' to
${_parent} and return empty frames []."
@@end

@@got-result
The child's result arrived as ${_msg}. Send "Supervisor: child reported:
${_msg}" to 'human', then terminate with an empty frames array.
@@end

1. Send a message to 'human': "Supervisor: spawning worker..."
2. Spawn a child with frames: ["@worker"], and dest "child"
3. Register a trap for "^child_died:" with handler frames:
   ["The child crashed: ${_interrupt}. Report this to 'human' and terminate."]
4. Return frames: ["@got-result"]
```

When the LLM returns `["@worker"]` in the spawn's frames, interpolation
expands it to the worker section text. The child process gets this as its
frame, and the runtime automatically appends the runtime preamble — so the
child knows about ops, interpolation, etc. without you repeating it.

The child has `${_parent}` bound to the parent's mailbox ID, so it can send
results back. The parent sleeps until the child's message arrives as
`${_msg}`. The `trap` for `child_died:` handles the case where the child
crashes instead of completing normally — the watcher sends a death
notification that the trap intercepts.

> **Important limitation:** The child receives the *resolved* section
> content as plain text — it does NOT inherit the parent's other section
> definitions. If the child returns `["@some-section"]` that was defined
> in the parent's boot frame, it won't resolve. For children that need
> multi-phase state machines, use the **binding-conditional single-frame**
> pattern below instead of section transitions.

### Disowned peers with blackboard discovery

Use `"disown": true` on `spawn` to create a fully independent peer agent:
no `${_parent}` binding, no death monitor. Disowned agents must discover
each other through shared services like the blackboard.

You can also give agents custom mailbox IDs with `"name": "worker"` on
`spawn`. This makes the child addressable by a known name instead of an
auto-generated `agent_N`. The name must be unique — a duplicate name
triggers op error recovery (`${_op_error}` is bound with details and the
remaining ops in the cycle are skipped).

Since children can't inherit parent sections (see above), use the
**binding-conditional single-frame** pattern: put the child's entire
multi-phase program in one section, use `@0` to loop, and check binding
presence to determine the current phase.

```
You are a coordinator. Spawn two disowned peers that discover each other.
Messages arrive between cycles as ${_msg}.

@@bank-program
You are the bank. You run in grind mode. Use receive ops to block.
Return frames: ["@0"] to loop.

Check your bindings to determine what to do:

If ${req} is in your bindings:
  ${req} is the text summary. ${req_payload} is the full JSON.
  If ${req} contains "balance_request":
    Parse ${req_payload} to extract the "reply_to" field.
    Send {"text": "balance:42"} to that reply address.
    Terminate with empty frames [].
  Otherwise: Issue receive("req"). Return frames: ["@0"].

If ${ack} is in your bindings but ${req} is NOT:
  Issue receive("req").
  Return frames: ["@0"].

Otherwise (first cycle):
  Send {"action": "write", "key": "bank_mb", "value": "${_self}"} to 'blackboard'.
  Issue receive("ack").
  Return frames: ["@0"].
@@end

@@wait-result
You are the coordinator. Do NOT spawn any agents.
A message arrived as ${_msg}.
If ${_msg} starts with "balance:":
  Send {"text": "Result: ${_msg}"} to 'human'. Terminate with [].
Otherwise: Return frames: ["@wait-result"]. No ops.
@@end

1. Spawn with frames: ["@bank-program"], dest "bank_id",
   "grind": true, "disown": true, "name": "bank".
2. Return frames: ["@wait-result"].
```

The pattern works because:
- **Bindings persist** across grind-mode cycles (as long as frames don't
  drain to `[]`), so the agent accumulates bindings as it progresses.
- **`@0` is self-referencing** — it injects the current frame's full text,
  so the same conditional logic runs every cycle.
- **Binding checks are ordered** most-advanced-phase first, so the agent
  falls through to the correct phase based on what bindings exist.
- **The child's entire program is self-contained** in one section — no
  cross-section references needed.

### Understanding grind and idle

The `--grind` and `--idle` flags control two independent axes of agent behavior.
Choosing the right combination is the most important design decision for an
agent's lifecycle.

**Cycle pacing** (`--grind`): Should the agent wait for a mailbox message
between cycles (message-driven, the default), or hot-loop continuously?

**Frame-exhaust behavior** (`--idle`): Should the agent terminate when its
frames drain to `[]` (the default), or restore the boot frame and wait for
more work?

| | **terminate on exhaust** (default) | **idle on exhaust** (`--idle`) |
|---|---|---|
| **message-driven** (default) | One-shot / request-response. Agent wakes on message, does work, terminates when frames drain to `[]`. | Daemon. Agent wakes on message, does work, idles back to boot frame to wait for more. |
| **grind** (`--grind`) | Worker loop. Agent hot-loops with explicit `receive` ops, terminates when frames drain to `[]`. | Hot-loop daemon. Agent hot-loops, restores boot frame on exhaust. Bindings reset. Rare. |

**Which combination to use:**

- **Message-driven + terminate** (default): Most agents. One-shot tasks,
  request-response children, multi-step workflows that terminate when frames
  drain to `[]`.
  Responses arrive as `${_msg}` between cycles — no `receive` ops needed.
- **Message-driven + idle**: Long-running daemons that handle many requests.
  Interactive bots, service agents. Combine with `--boot` so the boot frame
  defines the idle behavior. Bindings reset on idle restore.
- **Grind + terminate**: Autonomous worker loops. The child hot-loops with
  explicit `receive` ops to block for service responses (bash, blackboard).
  ~2x faster cycle throughput than message-driven. Use the two-cycle roll
  pattern below.
- **Grind + idle**: Rarely needed. A hot-looping daemon that restores its
  boot frame when frames drain. Bindings reset on restore. Consider whether
  message-driven + idle is simpler for your use case.

**Key things to remember:**

- In grind mode, `${_msg}` stays `"init"` after the first cycle — use
  `receive` ops to get data instead.
- Idle restore resets bindings to `{_self, _parent}`. Any accumulated
  bindings from `receive`/`spawn` are lost.
- Traps only fire in message-driven mode (between cycles). Grind mode has
  no inter-cycle message check.
- `receive` ops should only be used in grind mode. In message-driven mode,
  they consume the mailbox message and cause the inter-cycle wait to hang.

### Grind child with receive (two-cycle roll)

For a child that needs to call a service (like `bash`) and use the result
autonomously in a tight loop, use the **two-cycle roll** pattern. The child
runs in grind mode and uses `receive` to block for the service response,
but reports the result on the *next* cycle — because interpolation runs
before ops execute, so a binding from `receive` isn't available in the
same cycle's ops.

```
@@roller
You are the roller child. You autonomously roll random numbers in a
tight loop (grind mode — you cycle continuously without waiting for
messages between cycles).

EVERY cycle, do ALL of these steps in order:
1. If ${roll} is in your bindings: send {"text": "rolled:${roll}"} to ${_parent}
   and send {"text": "Child: I rolled ${roll}"} to 'human'.
2. Send {"command": "printf \"%d\" $(shuf -i 1-6 -n 1)"} to 'bash'.
3. Issue receive("roll") to block until bash responds.
4. Return frames: ["@0"].

On the first cycle ${roll} is not yet bound, so skip step 1.
On every subsequent cycle ${roll} holds the previous bash result.
@@end
```

Cycle 1 (no `${roll}`): Skip report. Send to bash, receive blocks,
`roll` gets bound. Return `@0`.

Cycle 2 (`${roll}` = "3"): Report "rolled:3" to parent. Send to bash,
receive blocks, `roll` gets overwritten with new value. Return `@0`.

Cycle 3+: Same as cycle 2 — report previous roll, start next roll.

The key insight: `receive("roll")` in cycle N updates the binding, and
`${roll}` in cycle N+1's ops is interpolated with that value *before*
the new receive executes. So the child always reports the *previous*
roll and starts the *next* one in the same cycle.

Spawn the child with `"grind": true`:

```json
{"op": "spawn", "frames": ["@roller"], "dest": "child", "grind": true}
```

No `idle` needed — the child loops via `@0` and never returns empty
frames.

### Idle child with trap (parent-driven ping-pong)

An alternative to the grind+receive pattern: the child runs in
message-driven mode with `idle: true` and the parent drives each roll
by sending `"roll"` messages. The parent uses a `trap` for child death
handling instead of checking `child_died:` in every section.

**Child (message-driven, idle):**

```
@@roller
You are the roller child. You roll random numbers when asked.
A message arrived as ${_msg} from ${_msg_source}.

If ${_msg} is "init" or "roll":
  1. Send {"command": "printf \"%d\" $(shuf -i 1-6 -n 1)"} to 'bash'.
  2. Return frames: ["@0"] to wait for the bash result.

Otherwise (${_msg} is a bash result — a number):
  1. Send {"text": "rolled:${_msg}"} to ${_parent}.
  2. Send {"text": "Child: I rolled ${_msg}"} to 'human'.
  3. Return frames: [] to go idle and wait for the next "roll" message.
@@end
```

The child handles two message types: commands (`"init"`, `"roll"`) and
bash results (numbers). On a command, it sends to bash and returns
`["@0"]` to wait for the response. On a bash result, it reports to the
parent and returns `[]` — idle mode restores the boot frame and the
child sleeps until the parent sends `"roll"`.

Spawn the child with `"idle": true`:

```json
{"op": "spawn", "frames": ["@roller"], "dest": "child", "idle": true}
```

**Parent (trap for death handling):**

The parent registers a trap on spawn:

```json
{"op": "trap", "pattern": "^child_died:", "frames": ["@death-handler"]}
```

When `child_died:` arrives, the trap fires regardless of which frame
the parent is in. The handler frames are prepended to the context stack
and execute immediately. No need to check for `child_died:` in every
section.

**Key differences from grind+receive:**

| | Grind + receive | Idle + trap |
|---|---|---|
| Child loop | grind mode, `receive` op | message-driven, `_msg` |
| Child pacing | autonomous hot loop | parent-driven via "roll" |
| Child death | explicit check in each section | trap fires anywhere |
| Stale messages | child runs ahead, parent drains | none — clean ping-pong |

The idle+trap pattern is simpler when you want tight parent control
over the child's pacing and don't want to handle stale messages.

## Common pitfalls

### 1. Using `${_msg}` to reference a response that hasn't arrived yet

**Wrong:**
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

`${_msg}` is interpolated *before* ops execute. It refers to the message
that woke *this* cycle, not the bash response (which hasn't arrived yet).

**Right:** Send the request, return a continuation frame, and use `${_msg}`
on the next cycle when the response has arrived:

```json
{
  "ops": [{"op": "send", "mailbox": "bash", "msg": {"command": "uname -a"}}],
  "frames": ["The bash output arrived as ${_msg}. Send 'Result: ${_msg}' to human, then terminate."],
  "notes": {}
}
```

### 2. Continuation frames that are too terse

**Wrong:** `frames: ["step2"]`

The LLM sees `"step2"` as its entire system prompt on the next cycle. It
has no idea what step 2 is.

**Right:** `frames: ["The bash output arrived as ${_msg}. Send 'Result: ${_msg}' to 'human' and terminate with empty frames."]`

Write continuation frames as if you're writing instructions for a new agent
that knows nothing about what happened before.

### 3. `@0` replaying one-time instructions

If your frame says "greet the user, then loop", `@0` will re-greet every
cycle. Use a `@@loop` section to separate setup from loop body.

### 4. Section names colliding with frame indices

Don't name a section `@@0` or `@@1` — these collide with frame index
references. Frame indices take priority over named sections in the sections
map.

### 5. Writing `@name` or `@@` markers inside continuation frames

If the LLM writes a continuation frame that contains `@worker` or `@@step2`
literally, the runtime will interpolate those references when processing the
response. This produces garbled frames. Only use `@name` references as
standalone frame entries like `["@step2"]`, never embedded in longer text.

### 6. Issuing a `receive` op in message-driven mode

**Wrong:**
```json
{
  "ops": [
    {"op": "send", "mailbox": "bash", "msg": {"command": "ls"}},
    {"op": "receive", "dest": "output"}
  ],
  "frames": ["Use ${output} somehow"],
  "notes": {}
}
```

The `receive` op consumes the bash response from the process mailbox. Then
the inter-cycle message wait *also* tries to read from the mailbox and
blocks forever — there's nothing left to read. The agent hangs.

**Right:** Don't use `receive`. The bash response arrives as `${_msg}` on
the next cycle automatically:

```json
{
  "ops": [{"op": "send", "mailbox": "bash", "msg": {"command": "ls"}}],
  "frames": ["The bash output arrived as ${_msg}. Use it."],
  "notes": {}
}
```

The `receive` op exists for grind-mode agents (`--grind`) that need to
explicitly block mid-cycle. In the default message-driven mode, all
responses arrive as `${_msg}` between cycles.

### 7. Using a `receive` result in the same cycle's ops or frames

**Wrong:**
```json
{
  "ops": [
    {"op": "send", "mailbox": "bash", "msg": {"command": "shuf -i 1-6 -n 1"}},
    {"op": "receive", "dest": "roll"},
    {"op": "send", "mailbox": "human", "msg": {"text": "You rolled ${roll}"}}
  ],
  "frames": ["Report ${roll} to parent."],
  "notes": {}
}
```

Interpolation runs *before* ops execute. `${roll}` is resolved against
the bindings from *before* this cycle's ops run — the `receive` hasn't
happened yet. So `${roll}` is either unresolved (literal `${roll}`) or
stale (from a previous cycle).

**Right:** Use the two-cycle pattern. Receive on cycle N, use the binding
on cycle N+1:

```json
{
  "ops": [
    {"op": "send", "mailbox": "bash", "msg": {"command": "shuf -i 1-6 -n 1"}},
    {"op": "receive", "dest": "roll"}
  ],
  "frames": ["@0"],
  "notes": {}
}
```

On the next cycle, `${roll}` is in the bindings and available for
interpolation. See the "Grind child with receive" pattern for a
complete example.

### 8. Child agents returning parent section references

**Wrong:**
```
@@worker
Do step 1, then return frames: ["@step2"]
@@end

@@step2
Do step 2...
@@end

Spawn with frames: ["@worker"]
```

The child receives the resolved `@worker` text as plain text. It does NOT
have `@@step2` — that section is defined in the parent's boot frame. When
the child returns `["@step2"]`, it stays as the literal string `"@step2"`
and the LLM gets no useful instructions.

**Right:** Put the child's entire multi-phase logic in a single section
using binding-conditional checks and `@0` to loop (see the "Disowned peers"
pattern above). Or keep the child simple enough to finish in one or two
cycles without needing section transitions.

### 9. Boot frame instructions re-executing on every cycle

The boot frame text (with `@@sections` visible) is included in the system
prompt on **every cycle**, not just the first. If you put "Step 1: spawn a
child" as plain text at the bottom of the boot frame, the LLM sees those
spawn instructions on cycle 2, 3, etc. and may re-execute them.

**Fix:** Either put first-cycle-only instructions inside a `@@section` (so
they appear as a definition, not a direct instruction), or make the current
frame's instructions clearly override with "Do NOT spawn" / "Do NOT re-run
step 1" language.

### 10. Issuing too many ops in one cycle

Each cycle should do one logical step. Don't pre-issue ops for future steps.
For example, don't send to `bash` and then immediately try to forward the
result to `human` in the same cycle — the result isn't available yet. Send
to `bash`, return a continuation frame, then send to `human` on the next
cycle when `${_msg}` has the response.

## Mailbox protocols

### human

Send a JSON object with a `"text"` field to display it on the user's terminal.

```json
{"op": "send", "mailbox": "human", "msg": {"text": "Hello, user!"}}
```

### human_input

Send a JSON object with a `"prompt"` field. The user's typed line (trimmed)
arrives as `${_msg}` on the next cycle.

```json
{"op": "send", "mailbox": "human_input", "msg": {"prompt": "Enter your name: "}}
```

### bash

Shell command execution with configurable timeout. Send a JSON object with
a `"command"` field:

```json
{"op": "send", "mailbox": "bash", "msg": {"command": "uname -a"}}
```

Output arrives as `${_msg}` on the next cycle. On failure: `"error: exit code N: ..."`.

**With timeout and mode** — add optional `"timeout"`, `"mode"`, and `"note"` fields:

```json
{"op": "send", "mailbox": "bash", "msg": {"command": "find / -name '*.log'", "timeout": 5000, "mode": "kill"}}
```

- **mode** `"kill"` (default): on timeout the command is terminated and you receive
  `"error: timeout after Nms"`.
- **mode** `"notify"`: on timeout the command keeps running and you receive a
  timeout notification with a handle. You can then control the job:

```json
{"op": "send", "mailbox": "bash", "msg": {"action": "kill", "handle": "<handle>"}}
{"op": "send", "mailbox": "bash", "msg": {"action": "wait", "handle": "<handle>"}}
{"op": "send", "mailbox": "bash", "msg": {"action": "wait", "handle": "<handle>", "timeout": 10000}}
```

The final result of a notify-mode job still arrives in the standard format
(stdout or error string) when the command eventually completes.

**Default timeout** is set by the runtime (`--bash-timeout`, typically 60 s).
Commands without a `"timeout"` field use the default timeout in kill mode.
Non-integer or negative `"timeout"` values are ignored (the default is used).
Use `0` for no timeout.

### blackboard

Key-value store. Send JSON objects with an `"action"` field. The result
arrives as `${_msg}` on the next cycle.

- **Write:** `{"action": "write", "key": "<key>", "value": "<value>"}` — returns `"ok"`
- **Read:** `{"action": "read", "key": "<key>"}` — returns the value (or empty
  string if key doesn't exist)

### watchdog

Timer service. Send JSON objects to the `"watchdog"` mailbox. Ticks
arrive as `"tick"` from source `"watchdog"`.

| Message | Behavior |
|---|---|
| `{"action": "every", "ms": N}` | Periodic ticks every N milliseconds |
| `{"action": "after", "ms": N}` | Single tick after N milliseconds |
| `{"action": "cancel"}` | Cancel all timers for the sender |
| `{"action": "list"}` | List active timers (reply sent back) |

All commands are fire-and-forget except `list`, which sends a reply.
The `ms` field must be a positive integer; invalid values return an error
message instead of scheduling. Multiple timers stack — an agent can have
several `every` and `after` timers simultaneously.

```json
{"op": "send", "mailbox": "watchdog", "msg": {"action": "every", "ms": 5000}}
```

To use a one-shot delayed tick:

```json
{"op": "send", "mailbox": "watchdog", "msg": {"action": "after", "ms": 3000}}
```

To cancel all your timers:

```json
{"op": "send", "mailbox": "watchdog", "msg": {"action": "cancel"}}
```

### batch

Fan out multiple service requests in parallel and collect all results in a
single cycle. Instead of sending N requests and waiting N cycles for responses,
send one batch request and get all results back at once.

```json
{"op": "send", "mailbox": "batch", "msg": {"requests": [
  {"mailbox": "bash", "msg": {"command": "uname -a"}},
  {"mailbox": "bash", "msg": {"command": "whoami"}},
  {"mailbox": "blackboard", "msg": {"action": "read", "key": "foo"}}
], "timeout": 30000}}
```

The response arrives as `${_msg}` on the next cycle:

```json
{
  "text": "batch complete: 3/3 succeeded",
  "results": [
    {"mailbox": "bash", "response": {"text": "Linux...", ...}},
    {"mailbox": "bash", "response": {"text": "root", ...}},
    {"mailbox": "blackboard", "response": {"text": "bar", ...}}
  ]
}
```

Results are ordered to match the original requests array. Sub-requests that
fail (unknown mailbox) or time out get error entries in their `"response"`.
The optional `"timeout"` field (default 30s) applies to the entire batch.

### eval

Evaluate Elixir expressions for math, string processing, and data
transformations without shelling out to bash.

```json
{"op": "send", "mailbox": "eval", "msg": {"code": "Enum.sum(1..100)"}}
```

Success response:

```json
{"text": "5050", "result": "5050", "type": "integer"}
```

Error response:

```json
{"text": "error: module not allowed: System", "error": "module not allowed: System"}
```

The optional `"timeout"` field (default 5s) limits evaluation time. Only
allowlisted modules may be used: `Kernel`, `Enum`, `Map`, `List`, `Keyword`,
`String`, `Integer`, `Float`, `Tuple`, `MapSet`, `Range`, `Stream`, `Regex`,
`Date`, `Time`, `DateTime`, `NaiveDateTime`, `Calendar`, `Access`, `Base`,
`URI`, `:math`, `:lists`, `:maps`, `:string`, `:binary`, `:calendar`, `:rand`,
`:unicode`, `:re`. All other modules are rejected at parse time.

Use `eval` for math (`1 + 2 * 3`), Enum/Map/String operations
(`String.upcase("hello")`), and data transformations. For shell commands, use
`bash` instead.

### factory

Create custom stateful services at runtime. Provide an arity-2 handler
function as a code string plus optional initial state. The factory compiles
it and wraps it in a GenServer with its own mailbox.

**Handler contract:** `fn(msg :: map, state :: any) -> {reply :: map | nil, new_state :: any}`

- `msg`: decoded JSON map from the sender
- `state`: service's current state (initialized from `"state"` field, default `%{}`)
- Returns `{reply, new_state}` — reply is routed to sender; `nil` = no reply

Create a service:

```json
{"op": "send", "mailbox": "factory", "msg": {"action": "create", "name": "counter", "code": "fn msg, state -> case msg[\"action\"] do \"inc\" -> {%{\"text\" => \"ok\", \"count\" => state + 1}, state + 1} _ -> {nil, state} end end", "state": 0}}
```

Response: `{"text": "ok", "name": "counter"}`. The created service registers
directly as mailbox `"counter"` — send to it like any other service.

Destroy a service:

```json
{"op": "send", "mailbox": "factory", "msg": {"action": "destroy", "name": "counter"}}
```

List active services:

```json
{"op": "send", "mailbox": "factory", "msg": {"action": "list"}}
```

Response: `{"text": "services: counter, cache", "services": ["cache", "counter"]}`

Handler exceptions are caught — the worker sends an error reply without
crashing, so subsequent messages still work. No AST sandboxing is applied
(agents already have bash access).

## CLI flags

| Flag | Effect |
|------|--------|
| `-v` | Lifecycle events, cycle headers, frames summary |
| `-vv` | + ops per cycle (send, receive, spawn, trap) |
| `-vvv` | + bindings, full frame content |
| `--thinking` | Enable extended thinking (Anthropic only) |
| `--model <id>` | LLM model to use (default: env var or `claude-sonnet-4-20250514`) |
| `--test` | Run built-in smoke tests |
| `--init <file>` | Generate a starter boot frame |
| `--max-cycles N` | Max eval cycles before terminating (default: 50, 0 = unlimited) |
| `--idle` | Idle (restore boot frame) when frames exhaust instead of terminating |
| `--boot <file>` | Separate boot frame file (used for idle recovery) |
| `--grind` | Hot-loop mode (no inter-cycle message wait) |
| `--watchdog <ms>` | Periodic tick messages at given interval |
| `--log-timings` | Show LLM call, cycle, wall-clock timing, and cache stats per eval cycle |
| `--log-full-prompts` | Show full system prompt and user message each cycle |
| `--runtime <file>` | Use custom runtime preamble instead of built-in |
| `--name <id>` | Custom mailbox ID for the root agent |
| `--each` | Spawn one agent per positional file (instead of stacking) |
| `--dump-runtime <file>` | Write the built-in runtime preamble to a file for editing |
| `--dry-run` | Print the full initial prompt (runtime + frames) to stdout and exit |
| `--list-models` | List available models from configured backend(s) |
| `--trace` | Emit NDJSON trace to stderr (silences logger) |
| `--trace-file <file>` | Emit NDJSON trace to file (silences logger) |
| `--trace-service` | Include service events in trace (bash, blackboard, watchdog, reaper) |
| `--trace-messages` | Include message routing events in trace |
| `--bash-timeout N` | Default bash command timeout in ms (default: 60000, 0 = none) |

Extended thinking (`--thinking`) gives the LLM a reasoning budget before
responding. This can help with complex multi-step tasks where the LLM needs
to plan its cycle carefully. It uses `tool_choice: "any"` instead of forced
tool use, and increases the max token budget to 16k.

### `--idle`

By default, when an agent's frame stack drains to `[]`, the agent terminates.
This is the natural behavior for one-shot and multi-step agents.

For long-running agents that should stay alive and wait for new work,
`--idle` restores the boot frame when frames drain, so the agent idles
until a message arrives. Useful with `--boot` for daemon-style agents.

### `--boot <file>` and multi-file stacks

Multiple positional files are loaded as frames (first file on the bottom of
the stack). Without `--boot`, the first file is both the boot frame and the
bottom of the stack. With `--boot`, the boot file is used for idle recovery
and all positional files are task frames stacked on top.

```bash
# task.txt is both boot frame and task
elixir gizmo.exs task.txt

# sys.txt is the boot frame, task.txt is stacked on top
elixir gizmo.exs --boot sys.txt task.txt
```

This lets you reuse a generic boot frame (with sections, idle behavior, etc.)

### `--name <id>`

Give the root agent a human-readable mailbox ID instead of auto-generated
`agent_1`. Useful for tracing, debugging, and addressing the agent by name
in boot frames.

```bash
elixir gizmo.exs --name mybot task.txt
```

In spawn ops, use `"name": "worker"` for the same effect on child agents.

### `--each`

Spawn one independent agent per positional file, instead of stacking all
files into a single agent's context stack. Each agent runs independently
with its own mailbox, bindings, and lifecycle.

```bash
# Two independent agents, one per file
elixir gizmo.exs --each a.txt b.txt

# Each agent gets sys.txt as boot frame
elixir gizmo.exs --each --boot sys.txt a.txt b.txt
```

`--each` cannot be combined with `--name` (ambiguous — which agent gets
the name?). The runtime waits for all agents to exit before shutting down.

### `--trace` and `--trace-file`

Trace mode emits one JSON object per line (NDJSON) with full cycle data for
every agent. This is the machine-readable alternative to `-v` / `--log-timings`
and is intended for post-run analysis, visualization, and debugging.

Either flag silences Logger output so only the JSON stream and stdout human
messages appear. Both flags can be used together (trace goes to both stderr
and file).

```bash
# Trace to stderr
elixir gizmo.exs --trace task.txt

# Trace to a file
elixir gizmo.exs --trace-file trace.jsonl task.txt

# Both (stderr + file)
elixir gizmo.exs --trace --trace-file trace.jsonl task.txt
```

#### Piping trace to jq

Since `--trace` writes to stderr, swap file descriptors to pipe into `jq`:

```bash
elixir gizmo.exs --trace task.txt 3>&1 1>&2 2>&3 | jq .
```

This sends trace (stderr) into the pipe and human output (stdout) to the
terminal.

To discard human output entirely:

```bash
elixir gizmo.exs --trace task.txt 2>&1 >/dev/null | jq .
```

With `--trace-file`, inspect after the run:

```bash
elixir gizmo.exs --trace-file trace.jsonl task.txt
jq . trace.jsonl
```

Or stream live in another terminal:

```bash
tail -f trace.jsonl | jq .
```

#### Event types

Three event types are emitted:

**`agent_start`** — emitted when an agent registers its mailbox.

```json
{"event":"agent_start","agent":"agent_1","parent":null,"t_ms":42}
```

**`agent_stop`** — emitted when an agent is about to clean up.

```json
{"event":"agent_stop","agent":"agent_1","t_ms":15230}
```

**`cycle`** — emitted after each eval cycle completes. Contains the full
system prompt, user message, interpolated ops, resulting frames, bindings,
notes, and token usage. On LLM error, `ops`/`frames`/`bindings`/`notes`/`usage`
are null and `error` contains the stringified reason.

```json
{
  "event": "cycle",
  "agent": "agent_1",
  "cycle": 1,
  "llm_ms": 2435,
  "cycle_ms": 2436,
  "t_ms": 2436,
  "system_prompt": "...",
  "user_content": "Begin.\n\nCurrent bindings:\n...",
  "ops": [{"op":"send","mailbox":"human","msg":{"text":"Hello!"}}],
  "frames": ["..."],
  "bindings": {"_self":"agent_1","_msg":"init"},
  "notes": {},
  "usage": {"input_tokens":1234,"output_tokens":567,"cache_creation_input_tokens":1234,"cache_read_input_tokens":0},
  "error": null
}
```

The `usage` field is populated for Anthropic API calls and `null` for OpenAI.
`cache_creation_input_tokens` and `cache_read_input_tokens` reflect prompt
caching behavior — on the first call you'll see creation tokens, and subsequent
calls with the same prefix will show read tokens instead.

#### Useful jq recipes

Compact one-line-per-event summary:

```bash
jq -r '
  if .event == "cycle" then
    "\(.agent) cycle=\(.cycle) llm=\(.llm_ms)ms ops=\(.ops | length) frames=\(.frames | length)"
  elif .event == "agent_start" then
    "\(.agent) START parent=\(.parent)"
  elif .event == "agent_stop" then
    "\(.agent) STOP t=\(.t_ms)ms"
  else . | tostring
  end
' trace.jsonl
```

Full JSON but truncate prompts:

```bash
jq '
  if .system_prompt then .system_prompt = (.system_prompt[:80] + "…") else . end |
  if .user_content then .user_content = (.user_content[:80] + "…") else . end
' trace.jsonl
```

Drop prompts entirely:

```bash
jq 'del(.system_prompt, .user_content)' trace.jsonl
```

Filter to a single agent in a multi-agent run:

```bash
jq 'select(.agent == "agent_1")' trace.jsonl
```

Show only error cycles:

```bash
jq 'select(.error != null)' trace.jsonl
```

Total LLM time across all cycles:

```bash
jq -s '[.[] | select(.event == "cycle") | .llm_ms] | add' trace.jsonl
```

Cache hit ratio across all cycles:

```bash
jq -s '
  [.[] | select(.event == "cycle" and .usage != null) | .usage] |
  { total_input: (map(.input_tokens) | add),
    cache_read: (map(.cache_read_input_tokens) | add),
    cache_create: (map(.cache_creation_input_tokens) | add) }
' trace.jsonl
```
across different task files.
