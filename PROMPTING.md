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

This also means **child processes** spawned via `fork` automatically get the
runtime preamble — you only need to provide task instructions in child frames.

The `--init` flag generates a starter template with a placeholder task section.

## The eval loop

Understanding the eval loop is critical for writing good prompts.

```
1. The context stack (list of frame strings) becomes the system prompt.
   Multiple frames are joined with "\n\n---\n\n".
   The runtime preamble is appended automatically after the frames.
2. The LLM is called with this system prompt.
3. The LLM returns: ops (syscalls to execute), frames (new context stack),
   and notes (annotations for bindings).
4. Interpolation runs on the returned ops and frames BEFORE ops execute.
5. Ops execute sequentially (send, receive, fork, join).
6. The returned frames become the new context stack.
7. If frames is empty []:
   - With `--quit-on-exhaust`: the agent terminates.
   - Otherwise: the boot frame is restored and the agent idles.
   - Agents can also terminate explicitly via `join`.
8. Otherwise, go to 1.
```

**Key timing rule:** Interpolation happens *before* ops run. If you issue a
`receive` op and a `send` op with `${output}` in the same eval cycle, the
`${output}` refers to whatever was in the bindings *before* the receive, not
the value the receive will produce. To use a received value, return a
continuation frame and reference `${output}` on the *next* cycle.

## Interpolation reference

All interpolation applies to the ops and frames the LLM returns. It does
**not** apply to the system prompt the LLM sees — the LLM sees raw text
including `${name}`, `@0`, section markers, etc.

### `${name}` — named bindings via `dest`

The bindings map holds values produced by `receive` and `fork` ops. Each of
these ops has a `dest` field that names where the result is stored.

```
# Agent issues: receive with dest "output"
# The received message "hello" is stored in bindings as output = "hello"
# On the next cycle, bindings show: ${output} = hello
# The LLM returns:
  ops:    [send("human", "you said: ${output}")]
  frames: []
  notes:  {}

# After interpolation:
  ops:    [send("human", "you said: hello")]
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

The simplest pattern. Do something, return empty frames. Run with
`--quit-on-exhaust` so the agent terminates cleanly on empty frames
instead of idling.

```bash
elixir gizmo.exs --quit-on-exhaust hello.txt
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
You are a system inspector. Do the following in order:

1. Send the command "uname -a" to the 'bash' mailbox.
2. Receive the result with dest "output" (it will appear as ${output} on
   your next eval).
3. Send a message to 'human' that says: "System info: ${output}"
4. Terminate with an empty frames array.

Start by sending the bash command and issuing a receive with dest "output",
then set your frames to a continuation prompt that reminds you to forward
the result to human once you have it.
```

Cycle 1: LLM sends the bash command, issues receive with dest "output",
returns a frame like "You received system info in ${output}. Send it to
human and terminate."

Cycle 2: `${output}` now contains the bash output. LLM sends it to human,
returns `[]`.

**Tip:** Tell the LLM to write *real prompts* as continuation frames, not
shorthand labels. A frame like `"step2"` gives the LLM nothing to work with
on the next cycle. A frame like `"You have the bash result in ${output}. Send
'System info: ${output}' to human, then return empty frames to terminate."`
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
You are an interactive echo-bot. This frame handles first-time setup.

@@loop
You are an interactive echo-bot, in the middle of a loop iteration.

The user's most recent input is in ${input}. Decide what to do:

- If ${input} is "quit": send "echo-bot: goodbye!" to 'human', then
  terminate with an empty frames array [].
- Otherwise: send "echo-bot: you said: ${input}" to 'human', then prompt
  for the next input by sending "echo-bot> " to 'human_input', then
  receive with dest "input". Return frames: ["@loop"] to continue the loop.
@@end

First-time setup:
1. Send a greeting to 'human'.
2. Send the prompt "echo-bot> " to 'human_input', then receive with dest
   "input".
3. Return frames: ["@loop"] to enter the loop.

After this first cycle, the @loop section takes over for all subsequent
iterations. You will NOT see this setup frame again.
```

Cycle 1 (setup frame): LLM greets, prompts, receives. Returns `["@loop"]`.
After interpolation, the context stack becomes the loop body text.

Cycle 2+ (loop body): LLM sees user input in `${input}`, echoes or quits.
Returns `["@loop"]` to keep going, or `[]` to stop.

This pattern cleanly separates one-time setup from the repeating loop.

### Fork with named sections as child prompts

When forking a child process, the child doesn't inherit the parent's context
stack — it gets its own frames. Define the child's task as a named section
in the parent's frame, and reference it with `@worker` in the fork frames.

```
You are a supervisor that delegates work to a child process.

@@worker
Send the command 'date +%s' to 'bash', receive the result with dest "ts",
then join with the message 'timestamp: ${ts}'. Use a continuation frame
between the send+receive and the join so you remember what to do next.
@@end

1. Send a message to 'human': "Supervisor: spawning worker..."
2. Fork a child with n=0, frames: ["@worker"], and dest "child"
3. Receive the child's join message with dest "result".
4. Send to 'human': "Supervisor: child reported: ${result}"
5. Terminate with an empty frames array.
```

When the LLM returns `["@worker"]` in the fork's frames, interpolation
expands it to the worker section text. The child process gets this as its
frame, and the runtime automatically appends the runtime preamble — so the
child knows about syscalls, interpolation, etc. without you repeating it.

The `${ts}` in the worker section text is safe because section content is
quoted verbatim. The `${ts}` survives as literal text in the child's prompt,
where the child's own interpolation will resolve it against the child's own
bindings.

## Common pitfalls

### 1. Using `${dest}` from a `receive` in the same cycle

**Wrong:**
```json
{
  "ops": [
    {"op": "receive", "dest": "data"},
    {"op": "send", "mailbox": "human", "msg": "Got: ${data}"}
  ],
  "frames": [],
  "notes": {}
}
```

The `${data}` in the send is interpolated *before* the receive runs, so it
refers to whatever was previously in that binding (or stays as literal
`${data}` if the binding didn't exist).

**Right:** Issue the receive, return a continuation frame, and use `${data}`
on the next cycle:

```json
{
  "ops": [{"op": "receive", "dest": "data"}],
  "frames": ["Send the received value (${data}) to human, then terminate."],
  "notes": {"data": "the received value"}
}
```

### 2. Continuation frames that are too terse

**Wrong:** `frames: ["step2"]`

The LLM sees `"step2"` as its entire system prompt on the next cycle. It
has no idea what step 2 is.

**Right:** `frames: ["You received the bash output in ${output}. Send 'Result: ${output}' to 'human' and terminate with empty frames."]`

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

### 6. Issuing a `receive` when you don't need one

Not every `send` needs a matching `receive`. Sending to `human` is
fire-and-forget — the message is displayed and no response comes back. Only
issue `receive` when you're sending to a mailbox that produces a reply
(`bash`, `blackboard`, `human_input`). A spurious `receive` on a terminal
step will cause the agent to hang forever waiting for a message that never
arrives.

### 7. Issuing too many ops in one cycle

Each cycle should do one logical step. Don't pre-issue ops for future steps.
For example, don't send to `bash` and then immediately try to forward the
result to `human` in the same cycle — the result isn't available yet. Send
to `bash`, receive with a dest name, return a continuation frame, then send
to `human` on the next cycle.

## Mailbox protocols

### human

Send a string to display it on the user's terminal.

```json
{"op": "send", "mailbox": "human", "msg": "Hello, user!"}
```

### human_input

Send a prompt string, then receive to get the user's typed input.

```json
{"op": "send", "mailbox": "human_input", "msg": "Enter your name: "}
```

Then issue a `receive` with a dest name. The user's typed line (trimmed)
is stored in `${dest}`.

### bash

Send a shell command string, then receive the output.

```json
{"op": "send", "mailbox": "bash", "msg": "uname -a"}
```

Then issue a `receive` with a dest name. stdout (with stderr merged) is
stored in `${dest}`. On failure, the message is `"error: exit code N: ..."`.

### blackboard

Key-value store. Send commands as strings:

- **Write:** `{write, key, value}` or `write key value`
- **Read:** `{read, key}` or `read key`

Then receive with a dest name. Write returns `"ok"` in `${dest}`. Read
returns the value (or empty string if the key doesn't exist).

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
| `--quit-on-exhaust` | Terminate when frames are exhausted instead of idling |
| `--boot <file>` | Separate boot frame file (used for idle recovery) |

Extended thinking (`--thinking`) gives the LLM a reasoning budget before
responding. This can help with complex multi-step tasks where the LLM needs
to plan its cycle carefully. It uses `tool_choice: "any"` instead of forced
tool use, and increases the max token budget to 16k.

### `--quit-on-exhaust`

By default, when an agent's frame stack drains to `[]`, the runtime restores
the boot frame and the agent idles (waiting for a message). This is useful
for long-running agents that receive work dynamically.

For one-shot or multi-step agents that should terminate when done,
`--quit-on-exhaust` makes the agent exit immediately on empty frames. Without
it, agents must use `join` to explicitly terminate.

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
