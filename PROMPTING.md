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
elixir gizmo.exs -v my_task.txt        # verbose (shows ops, frames, args)
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
3. The LLM returns: ops (syscalls to execute) and frames (new context stack).
4. Interpolation runs on the returned ops and frames BEFORE ops execute.
5. Ops execute sequentially (send, receive, fork, join).
6. The returned frames become the new context stack.
7. If frames is empty [], the agent terminates. Otherwise, go to 1.
```

**Key timing rule:** Interpolation happens *before* ops run. If you issue a
`receive` op and a `send` op with `$1` in the same eval cycle, the `$1`
refers to whatever was on the args stack *before* the receive, not the value
the receive will produce. To use a received value, return a continuation frame
and reference `$1` on the *next* cycle.

## Interpolation reference

All interpolation applies to the ops and frames the LLM returns. It does
**not** apply to the system prompt the LLM sees — the LLM sees raw text
including `$1`, `@0`, section markers, etc.

### `$n` — positional args

The args stack holds values pushed by `receive` and `fork`. `$1` is the most
recent value, `$2` the one before that, etc. (1-indexed.)

```
# Agent receives a message containing "hello"
# On the next cycle, args stack is ["hello"]
# The LLM returns:
  ops:    [send("human", "you said: $1")]
  frames: []

# After interpolation:
  ops:    [send("human", "you said: hello")]
```

Unresolved positional refs are left as-is. If the args stack has only one
entry, `$2` stays as the literal string `$2`.

### `${name}` — blackboard bindings

Reads from the blackboard key-value store. (Note: blackboard bindings are not
yet wired into the eval loop — this syntax is reserved for future use.)

```
# If blackboard has key "color" = "red":
  "The color is ${color}" → "The color is red"
  "Unknown: ${nope}"      → "Unknown: ${nope}"   (left as-is)
```

### `$$` — literal dollar sign

Use `$$` anywhere you need a literal `$` in output that won't be interpreted
as an interpolation reference.

```
  "Price: $$5"     → "Price: $5"
  "Escape: $$$$"   → "Escape: $$"
  "Keep: $$$1"     → "Keep: $hello"  (if $1 = "hello": $$ → $, then $1 → hello)
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
4. `${name}` → blackboard bindings
5. `$n` → positional args
6. Restore escape sentinels to literal `@` and `$`

The key consequence: section content is injected *before* `$` interpolation,
but all `$` characters in the injected content are escaped. So `$1` inside
a section stays as literal `$1` in the output — it won't be resolved against
the args stack. This is the "quoted verbatim" guarantee.

## Patterns

### One-shot agent

The simplest pattern. Do something, return empty frames.

```
You are a one-shot greeter. Send a short hello to the 'human' mailbox,
then terminate by returning an empty frames array.
```

The LLM returns:

```json
{
  "ops": [{"op": "send", "mailbox": "human", "msg": "Hello!"}],
  "frames": []
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
2. Receive the result (it will appear as $1 on your next eval).
3. Send a message to 'human' that says: "System info: $1"
4. Terminate with an empty frames array.

Start by sending the bash command and issuing a receive, then set your
frames to a continuation prompt that reminds you to forward the result
to human once you have it.
```

Cycle 1: LLM sends the bash command, issues receive, returns a frame like
"You received system info in $1. Send it to human and terminate."

Cycle 2: `$1` now contains the bash output. LLM sends it to human, returns
`[]`.

**Tip:** Tell the LLM to write *real prompts* as continuation frames, not
shorthand labels. A frame like `"step2"` gives the LLM nothing to work with
on the next cycle. A frame like `"You have the bash result in $1. Send
'System info: $1' to human, then return empty frames to terminate."` is much
better.

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

The user's most recent input is in $1. Decide what to do:

- If $1 is "quit": send "echo-bot: goodbye!" to 'human', then terminate
  with an empty frames array [].
- Otherwise: send "echo-bot: you said: $1" to 'human', then prompt for
  the next input by sending "echo-bot> " to 'human_input', then receive.
  Return frames: ["@loop"] to continue the loop.
@@end

First-time setup:
1. Send a greeting to 'human'.
2. Send the prompt "echo-bot> " to 'human_input', then receive.
3. Return frames: ["@loop"] to enter the loop.

After this first cycle, the @loop section takes over for all subsequent
iterations. You will NOT see this setup frame again.
```

Cycle 1 (setup frame): LLM greets, prompts, receives. Returns `["@loop"]`.
After interpolation, the context stack becomes the loop body text.

Cycle 2+ (loop body): LLM sees user input in `$1`, echoes or quits. Returns
`["@loop"]` to keep going, or `[]` to stop.

This pattern cleanly separates one-time setup from the repeating loop.

### Fork with named sections as child prompts

When forking a child process, the child doesn't inherit the parent's context
stack — it gets its own frames. Define the child's task as a named section
in the parent's frame, and reference it with `@worker` in the fork frames.

```
You are a supervisor that delegates work to a child process.

@@worker
Send the command 'date +%s' to 'bash', receive the result, then join with
the message 'timestamp: $1'. Use a continuation frame between the
send+receive and the join so you remember what to do next.
@@end

1. Send a message to 'human': "Supervisor: spawning worker..."
2. Fork a child with 0 frames popped from your stack, and give the child
   these frames: ["@worker"]
3. Receive the child's join message (it will become $1).
4. Send to 'human': "Supervisor: child reported: $1"
5. Terminate with an empty frames array.
```

When the LLM returns `["@worker"]` in the fork's frames, interpolation
expands it to the worker section text. The child process gets this as its
frame, and the runtime automatically appends the runtime preamble — so the
child knows about syscalls, interpolation, etc. without you repeating it.

The `$1` in the worker section text (`'timestamp: $1'`) is safe because
section content is quoted verbatim. The `$1` survives as literal text in
the child's prompt, where the child's own interpolation will resolve it
against the child's own args stack.

## Common pitfalls

### 1. Using `$1` from a `receive` in the same cycle

**Wrong:**
```json
{
  "ops": [
    {"op": "receive"},
    {"op": "send", "mailbox": "human", "msg": "Got: $1"}
  ],
  "frames": []
}
```

The `$1` in the send is interpolated *before* the receive runs, so it refers
to whatever was previously on the args stack (or stays as literal `$1` if
the stack was empty).

**Right:** Issue the receive, return a continuation frame, and use `$1` on
the next cycle:

```json
{
  "ops": [{"op": "receive"}],
  "frames": ["Send the received value ($1) to human, then terminate."]
}
```

### 2. Continuation frames that are too terse

**Wrong:** `frames: ["step2"]`

The LLM sees `"step2"` as its entire system prompt on the next cycle. It
has no idea what step 2 is.

**Right:** `frames: ["You received the bash output in $1. Send 'Result: $1' to 'human' and terminate with empty frames."]`

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
to `bash`, receive, return a continuation frame, then send to `human` on the
next cycle.

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

Then issue a `receive`. The user's typed line (trimmed) is pushed as `$1`.

### bash

Send a shell command string, then receive the output.

```json
{"op": "send", "mailbox": "bash", "msg": "uname -a"}
```

Then issue a `receive`. stdout (with stderr merged) is pushed as `$1`.
On failure, the message is `"error: exit code N: ..."`.

### blackboard

Key-value store. Send commands as strings:

- **Write:** `{write, key, value}` or `write key value`
- **Read:** `{read, key}` or `read key`

Then receive. Write returns `"ok"` as `$1`. Read returns the value (or empty
string if the key doesn't exist).

Both comma-separated and space-separated formats are accepted. Braces are
optional.

## CLI flags

| Flag | Effect |
|------|--------|
| `-v`, `--verbose` | Print ops, frames, and args each cycle |
| `--thinking` | Enable extended thinking (Anthropic only) |
| `--test` | Run built-in smoke tests |
| `--init <file>` | Generate a starter boot frame |

Extended thinking (`--thinking`) gives the LLM a reasoning budget before
responding. This can help with complex multi-step tasks where the LLM needs
to plan its cycle carefully. It uses `tool_choice: "any"` instead of forced
tool use, and increases the max token budget to 16k.
