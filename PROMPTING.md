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
elixir gizmo.exs -v my_task.txt        # verbose (shows ops, frames, bindings)
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

- `${_msg}` — the message that woke this cycle
- `${_msg_source}` — the sender's mailbox ID
- `${_self}` — this agent's mailbox ID
- `${_parent}` — the parent agent's mailbox ID (spawned children only)

The `spawn` op also creates bindings via its `dest` field.

```
# Agent sent "uname -a" to bash last cycle. Bash response woke this cycle.
# Bindings show: ${_msg} = Linux hostname 6.18... , ${_msg_source} = bash
# The LLM returns:
  ops:    [send("human", "System info: ${_msg}")]
  frames: []
  notes:  {}

# After interpolation:
  ops:    [send("human", "System info: Linux hostname 6.18...")]
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
  ops: [send("human", "@greeting")]

# After interpolation:
  ops: [send("human", "Hello, welcome to the system!")]
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
  "ops": [{"op": "send", "mailbox": "human", "msg": "Hello!"}],
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
The user typed "quit". Send "echo-bot: goodbye!" to 'human'.
Return frames: [] to terminate.
@@end

@@loop
The user's most recent input arrived as ${_msg}. Decide what to do:

- If ${_msg} is "quit": return frames ["@quit"] with no ops.
- Otherwise: send "echo-bot: you said: ${_msg}" to 'human', then
  send "echo-bot> " to 'human_input'. Return frames: ["@loop"].
@@end

First-time setup:
1. Send a greeting to 'human'.
2. Send the prompt "echo-bot> " to 'human_input'.
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

## Common pitfalls

### 1. Using `${_msg}` to reference a response that hasn't arrived yet

**Wrong:**
```json
{
  "ops": [
    {"op": "send", "mailbox": "bash", "msg": "uname -a"},
    {"op": "send", "mailbox": "human", "msg": "Result: ${_msg}"}
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
  "ops": [{"op": "send", "mailbox": "bash", "msg": "uname -a"}],
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
    {"op": "send", "mailbox": "bash", "msg": "ls"},
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
  "ops": [{"op": "send", "mailbox": "bash", "msg": "ls"}],
  "frames": ["The bash output arrived as ${_msg}. Use it."],
  "notes": {}
}
```

The `receive` op exists for grind-mode agents (`--grind`) that need to
explicitly block mid-cycle. In the default message-driven mode, all
responses arrive as `${_msg}` between cycles.

### 7. Issuing too many ops in one cycle

Each cycle should do one logical step. Don't pre-issue ops for future steps.
For example, don't send to `bash` and then immediately try to forward the
result to `human` in the same cycle — the result isn't available yet. Send
to `bash`, return a continuation frame, then send to `human` on the next
cycle when `${_msg}` has the response.

## Mailbox protocols

### human

Send a string to display it on the user's terminal.

```json
{"op": "send", "mailbox": "human", "msg": "Hello, user!"}
```

### human_input

Send a prompt string. The user's typed line (trimmed) arrives as `${_msg}`
on the next cycle.

```json
{"op": "send", "mailbox": "human_input", "msg": "Enter your name: "}
```

### bash

Send a shell command string. The output (stdout with stderr merged) arrives
as `${_msg}` on the next cycle. On failure, the message is
`"error: exit code N: ..."`.

```json
{"op": "send", "mailbox": "bash", "msg": "uname -a"}
```

### blackboard

Key-value store. Send commands as strings. The result arrives as `${_msg}`
on the next cycle.

- **Write:** `{write, key, value}` or `write key value` — returns `"ok"`
- **Read:** `{read, key}` or `read key` — returns the value (or empty
  string if key doesn't exist)

Both comma-separated and space-separated formats are accepted. Braces are
optional.

## CLI flags

| Flag | Effect |
|------|--------|
| `-v`, `--verbose` | Print ops, frames, and bindings each cycle |
| `--thinking` | Enable extended thinking (Anthropic only) |
| `--test` | Run built-in smoke tests |
| `--init <file>` | Generate a starter boot frame |
| `--max-cycles N` | Max eval cycles before terminating (default: 50, 0 = unlimited) |
| `--idle` | Idle (restore boot frame) when frames exhaust instead of terminating |
| `--boot <file>` | Separate boot frame file (used for idle recovery) |
| `--grind` | Hot-loop mode (no inter-cycle message wait) |
| `--watchdog <ms>` | Periodic tick messages at given interval |

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
across different task files.
