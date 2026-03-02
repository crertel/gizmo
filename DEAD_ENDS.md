# Dead Ends

Things we tried that didn't work, and why we moved away from them.

## Positional Args Stack (`$1`, `$2`, ...)

**Introduced:** `ccf67f0` (Stage 5: Well-known services)
**Removed:** replaced by named bindings via `dest` + `notes`

The original design had a GenServer-backed args stack. When `receive()` or
`fork()` returned a value, it was pushed onto the stack. The LLM could
reference values positionally: `$1` was the most recent, `$2` the one before
that, etc. Values were also injected into the user message as `$1 = value`.

### Why it didn't work

- **Indices shifted on every push.** A `receive` pushed a new value, so what
  was `$1` became `$2`. The LLM had to mentally track the push history to know
  which index held which value—fragile and error-prone.
- **No way to trace provenance.** Given `$3`, you couldn't tell whether it came
  from a `receive`, a `fork`, or which op produced it. The LLM had to count
  backwards through the ops it had issued across potentially multiple cycles.
- **Unbounded growth.** The stack only grew. Old values never expired. In a
  long-running agent with many receives, the stack accumulated stale data that
  was never referenced again but still occupied context.
- **Awkward in continuation frames.** When writing a continuation frame like
  `"The bash output is in $1. Now send it to human."`, the author had to know
  exactly how many pushes would happen between writing the frame and it being
  evaluated. Off-by-one errors were easy.

### What replaced it

Named bindings via `dest`. The `receive` and `fork` ops now take a `dest`
string field that names the binding:

```json
{"op": "receive", "dest": "output"}
{"op": "fork", "n": 0, "frames": ["child task"], "dest": "worker"}
```

The result is stored in a bindings map and referenced as `${output}` or
`${worker}`. A `notes` field on the eval response lets the LLM annotate
bindings with descriptions that persist across cycles:

```json
{"notes": {"output": "stdout from ls -la"}}
```

No GenServer needed—bindings are a plain map threaded through the eval loop.

## Text-Based `<ops>`/`<frames>` Parsing

**Introduced:** original architecture design (`c355d25`)
**Removed:** `eb30604` (Stage 2: Structured output)

The original design had the LLM emit ops and frames in delimited text blocks
(`<ops>` and `<frames>` XML-ish tags). A parser extracted and validated them.

### Why it didn't work

- **Parsing ambiguity.** The LLM could produce subtly malformed output—missing
  closing tags, extra whitespace, ops split across lines in unexpected ways.
  Edge cases multiplied.
- **Structured output already existed.** Both Anthropic (forced `tool_use`) and
  OpenAI (`json_schema` response format) support returning typed JSON directly.
  Using the provider's built-in structured output enforcement eliminated the
  parser entirely.
- **Schema validation for free.** With forced tool calls, the provider rejects
  malformed output before it reaches us. No retry-on-parse-failure needed for
  structural issues.

### What replaced it

The `eval_response` forced tool call. The LLM returns a JSON object with `ops`
(array of op objects), `frames` (array of strings), and `notes` (object).
Provider-level schema enforcement means we only validate semantic constraints
(e.g., "send requires mailbox and msg"), not structural ones.

## `spawn_link` for Forked Children

**Introduced:** `ccf67f0` (Stage 5/8: Fork implementation)
**Changed:** `9a916fc` (Exception service and child death monitoring)

Initially, forked children were spawned with `spawn_link`, linking the child's
lifecycle to the parent. If the child crashed, the parent crashed too.

### Why it didn't work

- **Cascading failures.** A child crash killed the parent, which killed the
  parent's parent, etc. One bad child could take down an entire agent tree.
- **No recovery path.** The parent couldn't catch the crash, report it, or
  spawn a replacement. It just died.
- **Didn't match the process calculus model.** In the actor model, process
  death is a message, not a contagion. The parent should be *notified* of child
  death, not killed by it.

### What replaced it

`spawn` (no link) with `Process.monitor`. A watcher process monitors the child
and sends a `child_died:` message to the parent's mailbox if the child crashes.
The parent receives this as a normal message and can react to it in its eval
loop.

## LLM Response Streaming

**Listed in:** Stage 1 (LLM Client) as optional
**Dropped:** never implemented

### Why we don't need it

- **Forced tool calls return structured JSON.** You can't act on a partial
  `eval_response` — you need the complete object to validate ops and execute
  them. Streaming tokens of incomplete JSON has no value.
- **The human never sees raw LLM output.** Users see messages via `send` ops
  to the `human` mailbox, which only fire *after* the full response is parsed
  and ops execute. There's no one watching tokens appear.
- **It's a machine-to-machine eval loop.** Time-to-first-token latency
  perception doesn't matter when the consumer is the runtime, not a person
  staring at a cursor.

## Telemetry

**Listed in:** Stage 10 (Polish and Hardening)
**Dropped:** never implemented

### Why we don't need it

- **Heavyweight for a single-file script.** Adding `:telemetry` as a dependency,
  defining event names, wiring up handlers—all for a `gizmo.exs` that runs
  via `elixir gizmo.exs`.
- **Verbose mode already covers debugging.** `IO.puts` in verbose mode shows
  cycles, ops, frames, and bindings. That's the debugging surface we actually
  use.
- **No consumer.** Who's ingesting these metrics? There's no dashboard, no
  alerting, no Prometheus endpoint. Telemetry without a consumer is dead code.

## Boot Frame Templating

**Listed in:** Stage 10 (Polish and Hardening)
**Dropped:** never implemented

### Why we don't need it

- **Boot frames are already just text files.** There's nothing to "templatize"
  that isn't already handled by the existing interpolation system (`${name}`
  for bindings, `@name` for sections).
- **"Parameterize mailbox registry" is vague.** The well-known mailboxes
  (`bash`, `human`, `blackboard`) are fixed names. An agent that needs a
  custom service just sends to whatever mailbox ID it knows about—no template
  needed.

## Hardcoded Cycle Limit as the Only Termination Strategy

**Introduced:** Stage 6 (Agent Process)
**Fixed:** Stage 10 (CLI Runtime Options)

One-shot agents that returned `frames: []` without `join` would idle
forever — the boot frame was restored, the cycle counter reset, and
`max_eval_cycles` never fired. This meant even a simple "hello world" agent
burned 50 LLM calls before the runtime killed it.

### Why it didn't work

- **Cycle counter reset on idle.** The idle clause restored the boot frame
  and reset retries to 0, but preserved the cycle count. Before that fix,
  cycles reset too, so the 50-cycle limit never triggered.
- **No way to say "just stop."** The only exit paths were `join` (which
  required awareness of the parent protocol) or hitting the cycle limit
  (expensive). There was no clean "I'm done, don't idle" option.
- **One size didn't fit all.** A 50-cycle limit is too high for one-shot
  agents and too low for long-running interactive agents.

### What replaced it

- Terminate-on-exhaust is now the default — agents exit on empty frames.
- `--idle` — opt-in to restore boot frame and idle on empty frames.
- `--max-cycles N` — configurable cycle limit, with 0 meaning unlimited.
- Both options propagate to spawned children.

## Grinding Eval Loop as Default

**Introduced:** Stage 6 (Agent Process)
**Changed:** Stage 12 (Message-Driven Eval Loop)

The eval loop originally ran as a hot grind — call the LLM, execute ops, loop
immediately. This was the simplest implementation and matched the "rewrite rule"
mental model.

### Why it didn't work

- **Wasted LLM calls.** A one-shot hello agent burned 50 calls spinning on an
  idle boot frame before the cycle limit killed it. Each idle cycle was a full
  LLM round-trip that returned "nothing to do."
- **Didn't match the actor model.** Processes should react to messages, not
  spin. A process with no work should sleep, not poll.
- **Complicated fork/join.** The parent had to pair `fork` + `receive` in the
  same op list to avoid spinning while waiting for the child. This was fragile
  and unnatural — in the actor model, you fork and naturally wake when the
  child's join message (or death notification) arrives.
- **No interrupt mechanism.** Without inter-cycle message checking, there was no
  way to preempt an agent's current work when a high-priority message arrived.

### What replaced it

- **Message-driven eval loop** (default). Agents sleep between cycles via
  `receive` and wake when a message arrives. `${_msg}` and `${_msg_source}`
  bindings provide the wake reason.
- **Grind mode** (`--grind`). Opt-in hot loop for worker agents that need to
  churn without external stimulus. Preserves the original behavior.
- **Trap op.** Single-slot interrupt handler that fires when an inter-cycle
  message matches a regex pattern. `trap(pattern, [])` clears the trap.
  Enables priority handling and simplified fork/join (parent sleeps, child's
  join message wakes it).
- **Watchdog service.** Periodic tick messages for agents that need a heartbeat.

## `untrap` as a Separate Op

**Introduced:** Stage 12 (initial implementation)
**Removed:** Stage 12 (same stage, during review)

The initial trap design had two ops: `trap(pattern, frames)` to register an
interrupt handler and `untrap()` to clear it.

### Why it didn't work

- **`trap(pattern, [])` and `untrap()` are the same instruction.** From the
  LLM's perspective, "set handler frames to empty" and "clear the trap" have
  no meaningful observable difference. In both cases, no frames get prepended
  to the stack on match.
- **The only distinction was an implementation leak.** `trap(pattern, [])` would
  still match messages and bind `${_interrupt}`, while `untrap()` would prevent
  matching entirely. But an LLM has no reason to want "match and bind but don't
  do anything" — that's a runtime bookkeeping detail, not a useful semantic.
- **Two ops for one concept.** Having both created ambiguity: an LLM that wanted
  to stop trapping could reasonably reach for either one. Worse, `trap(".*", [])`
  when the LLM meant `untrap` would silently do the wrong thing (still matching,
  still binding `_interrupt`).

### What replaced it

`trap(pattern, [])` with empty frames clears the trap. One op, no ambiguity.
Empty handler frames = nothing to prepend = no trap.

## `fork`/`join` as Process Calculus Primitives

**Introduced:** Stage 8 (Fork and Join)
**Removed:** Stage 12 (replaced by `spawn` + message-driven wake)

The original op set was `send`, `receive`, `fork`, `join` — modeled on process
calculus. `fork(n, frames, dest)` spawned a child and popped `n` frames from the
parent's stack. `join(msg)` sent a message to the parent and terminated.

### Why it didn't work

- **`join` is `send` + empty frames.** `join(msg)` sends a message to the parent
  and terminates. But `send(parent, msg)` with `frames: []` does the same thing.
  Once the eval loop became message-driven, the parent naturally wakes when the
  child's message arrives — no special "join" protocol needed. `join` was
  syntactic sugar that gave the LLM two ways to say "I'm done, here's my result."
- **`fork`'s `n` parameter was vestigial.** The `n` parameter popped frames from
  the parent's returned stack, but the LLM already controls what frames it
  returns for itself. It can just return fewer frames. The pop-during-execution
  mechanism solved a problem that doesn't exist.
- **Implicit parent routing was a hidden dependency.** `join` implicitly knew the
  parent's mailbox ID via `state.parent`, but this was invisible to the LLM. The
  child couldn't send to the parent any other way, creating an asymmetry: the
  parent had `${child_mb}` as a binding, but the child had no corresponding
  `${parent_mb}`. The runtime hid the parent address behind a special op instead
  of making it a normal binding.
- **The terminology obscured what was really an actor system.** "Fork" implies
  splitting a process. "Spawn" is the actor model term for creating a new process
  with work to do. Once the eval loop became message-driven and agents started
  sleeping between cycles, the system was an actor system in everything but name.

### What replaced it

- **`spawn(frames, dest)`** — create a child process with the given frames, store
  its mailbox ID in `dest`. No `n` parameter, no stack splitting.
- **`_self` and `_parent` bindings** — the runtime provides every agent its own
  mailbox ID as `${_self}`, and children get `${_parent}` pointing to their
  spawner. The LLM can send to either address with the normal `send` op.
- **Termination is just `frames: []`.** No special op needed. To terminate with
  a result, `send` first, then return empty frames.
- **Op set evolution:** `send`, `receive`, `fork`, `join` → `send`, `receive`,
  `fork`, `join`, `trap`, `untrap` → `send`, `receive`, `fork`, `join`, `trap`
  → `send`, `receive`, `spawn`, `trap`.

## Idle-by-Default (Boot Frame Restore on Empty Frames)

**Introduced:** Stage 6 (Agent Process)
**Changed:** Stage 12 (terminate-on-exhaust becomes default)

When an agent returned `frames: []`, the runtime restored the boot frame and
idled, waiting for new work. `--quit-on-exhaust` was added in Stage 10 as an
opt-in flag to terminate instead.

### Why it didn't work

- **Wrong default for most agents.** One-shot and multi-step agents are the
  common case. They do their work, return `frames: []`, and expect to stop.
  Having to pass `--quit-on-exhaust` every time was friction for the normal path.
- **Surprising for LLM-authored prompts.** An LLM following the runtime prompt's
  instruction to "return empty frames to terminate" would find its agent idling
  instead. The semantics didn't match the documentation.
- **Long-running agents are opt-in, not the default.** Daemon-style agents that
  should idle and wait for work are a specialized pattern, not the common case.

### What replaced it

Terminate-on-exhaust is now the default. `--idle` is the opt-in flag for agents
that should restore the boot frame and wait for messages on empty frames.

## Deferred Frame Transitions in Message-Driven Mode

**Discovered:** Stage 12 (test frame 05_loop.txt)

Test frames 05 and 06 used a two-step quit pattern: the `@loop` frame returned
`frames: ["@quit"]` with no ops, expecting the `@quit` frame to execute on the
next cycle and send the goodbye message.

### Why it didn't work

In message-driven mode, every cycle starts by blocking on `maybe_wait_for_message`.
Returning `frames: ["@quit"]` means the next cycle blocks waiting for a mailbox
message before evaluating the `@quit` frame. Since quit happens when the user is
done, no message arrives — the agent hangs forever.

This is correct behavior for the runtime: the agent has frames to process but
needs a message to trigger the next cycle. The bug was in the prompt design.

### What replaced it

Inline the quit behavior directly. Instead of `frames: ["@quit"]`, the `@loop`
frame sends the goodbye message and returns `frames: []` in the same cycle.

**Rule of thumb:** In message-driven mode, any frame transition that doesn't
need new input should be handled in the current cycle, not deferred to a new
frame that would block on a message.

## Split Output Across Human and HumanInput Services

**Discovered:** Stage 12 (test frame 05_loop.txt)

Test frames sent the echo/response to the `human` service and the input prompt
to `human_input` as two separate ops. The expectation was that `human` would
print first (since its op came first), then `human_input` would print the prompt.

### Why it didn't work

Both services are separate GenServers. Mailbox routing delivers messages
asynchronously. Even though the `send` to `human` executes before the `send`
to `human_input`, the GenServers process their messages independently. The
`human_input` service can print its prompt before `human` prints the response,
producing garbled output like `echo-bot> echo-bot: you said: hello`.

### What replaced it

Combine output and prompt into a single send to `human_input`, separated by a
newline. Since `human_input` is one GenServer, it processes sequentially: print
the combined text, then block on `IO.gets`. Output ordering is guaranteed.

## Same-Cycle Receive + Interpolation in Grind Mode

**Discovered:** Stage 13 (test frame 08_lucky_number.txt)

A grind-mode child that sent to `bash`, issued `receive("result")`, and then
used `${result}` in subsequent ops in the *same* cycle — expecting the receive
to bind `result` before the sends ran.

### Why it didn't work

Interpolation runs *before* ops execute. All `${name}` references in the cycle's
ops and frames are resolved against bindings from *before* any ops run. The
`receive` op updates bindings during execution, but the sends were already
interpolated with the pre-execution bindings. So `${result}` was either
unresolved (literal `${result}`) or stale.

Combined with idle mode, this produced a second failure mode: idle restore
resets bindings to `init_bindings` (only `_self`, `_parent`). In grind mode
(non-first cycle), `maybe_wait_for_message` doesn't re-bind `_msg`. So
`${_msg}` was also unresolved on post-idle cycles, producing literal `${_msg}`
in output.

### What replaced it

The **two-cycle roll** pattern. Cycle N does `send(bash)` + `receive("roll")`
and returns `@0`. Cycle N+1 has `${roll}` in bindings from the previous
receive, so `${roll}` in ops is interpolated correctly. The child reports the
previous result and starts the next receive in the same cycle, creating a
continuous grind loop without idle.

See PROMPTING.md "Grind child with receive (two-cycle roll)" for the full
pattern.

## Section-Based State Machines in Spawned Children

**Discovered:** Stage 8 (test frame 10_marketplace.txt)

The first marketplace test frame defined child agent phases as separate
`@@sections` in the parent's boot frame: `@@bank`, `@@bank-wait`,
`@@bank-handle`, etc. The parent spawned with `frames: ["@bank"]`, which
resolved to the bank section content. The child then returned
`frames: ["@bank-wait"]` to transition phases.

### Why it didn't work

- **Children don't inherit parent sections.** When a parent spawns with
  `frames: ["@bank"]`, the runtime interpolates `@bank` and passes the
  *resolved plain text* to the child. The child's boot frame is just a
  string — it has no `@@bank-wait` or `@@bank-handle` section definitions.
  Those definitions exist only in the parent's persisted sections.
- **Unresolved references become literal text.** When the child returned
  `frames: ["@bank-wait"]`, the runtime tried to resolve `@bank-wait`
  against the child's sections (empty). The frame stayed as the literal
  string `"@bank-wait"`. The LLM's system prompt on the next cycle was
  just the runtime preamble + the child's boot text + `"@bank-wait"`.
- **LLM had no instructions.** Seeing `"@bank-wait"` as its current
  frame, the LLM had no context for what to do. It returned
  `frames: ["@bank-wait"]` again without issuing any ops, creating an
  infinite spin loop in grind mode.
- **Sections can't be nested.** Even if you tried to include all section
  definitions inside the child's spawn frame (e.g., `@@bank` containing
  `@@bank-wait...@@end`), the non-greedy section regex matches the
  *first* `@@end`, truncating nested content.

### What replaced it

The **binding-conditional single-frame** pattern. Each child's entire
multi-phase program lives in a single section. The child uses `@0` to
loop and checks which bindings are present to determine its current phase.
Bindings accumulate across grind-mode cycles, so the agent progresses
through phases by acquiring new bindings (via `receive`) each cycle.

See PROMPTING.md "Disowned peers with blackboard discovery" for the full
pattern.

## Boot Frame Re-Execution on Non-First Cycles

**Discovered:** Stage 8 (test frame 10_marketplace.txt)

The first marketplace test frame had "Step 1: spawn bank and store" as
plain text at the bottom of the boot frame. On cycle 1, the coordinator
correctly executed step 1 (spawned children, transitioned to the polling
frame). On cycle 2, the coordinator spawned two more children.

### Why it didn't work

- **Boot frame is always in the system prompt.** On non-first cycles, the
  system prompt is `[runtime preamble, boot_text, current_frame_text]`
  (line 2101 of gizmo.exs). The raw boot frame — including all `@@section`
  definitions and any plain text — is visible to the LLM every cycle.
- **Plain-text instructions look like current directives.** The LLM on
  cycle 2 saw both "Step 1: spawn bank and store" (from boot frame) and
  the polling frame (from current frame). Despite the polling frame saying
  to check the blackboard, the LLM also followed the spawn instructions
  from the boot frame, producing duplicate agents.
- **Sections are definitions, plain text is imperative.** `@@step1...@@end`
  in the boot frame reads as a definition the LLM can reference. Bare
  "Step 1: spawn..." reads as an instruction to execute *now*.

### What replaced it

Two complementary fixes:

1. **Put first-cycle instructions inside a `@@section`.** Instead of bare
   text at the bottom, wrap step-1 instructions in `@@step1...@@end` and
   reference them with `@step1`. Section definitions in the boot frame are
   visible but read as reference material, not imperative instructions.
2. **Strong anti-re-execution language in continuation frames.** The
   `@wait-result` frame explicitly says "You already spawned the bank and
   store. Do NOT spawn any agents. Do NOT issue any ops." This overrides
   any spawn-related text the LLM sees in the boot frame.

## Checking `${_msg}` in Grind-Mode Children

**Discovered:** Stage 8 (test frame 10_marketplace.txt)

The bank agent ran in grind mode and used `${_msg}` to detect incoming
balance requests in its `@bank-wait` phase: "If ${_msg} starts with
balance_request:, extract the sender and respond."

### Why it didn't work

- **`_msg` is NOT re-bound in grind mode after the first cycle.** This is
  an existing invariant (see "Same-Cycle Receive + Interpolation in Grind
  Mode" above), but it has a non-obvious consequence for grind children
  waiting for external messages: `${_msg}` stays as `"init"` forever.
- **The bank spun without ever seeing the request.** The store sent
  `"balance_request:agent_5"` to the bank's mailbox, but the bank was in
  grind mode and never called `receive`. The message sat in the mailbox
  while the bank checked `${_msg}` (always `"init"`) in a tight loop.

### What replaced it

Grind-mode agents that need to receive external messages must use explicit
`receive("dest")` ops. The bank-wait phase issues `receive("req")` which
blocks until a message arrives, then the bank-handle phase checks `${req}`
(not `${_msg}`). This is the two-cycle roll pattern applied to message
reception rather than service calls.

## String-Based Message Protocols

**Introduced:** Stage 5 (Well-known services)
**Removed:** replaced by JSON object messages

Messages between agents and services were plain strings with ad-hoc formats.
Each service had its own text protocol: `"write key value"` for blackboard,
`"open /path/to/file"` for the pager, `"every 5000"` for watchdog. The `msg`
field in send ops was a string. Service responses were also strings.

### Why it didn't work

- **Fragile parsing.** Every service needed a custom `parse_command/1` or
  `parse_message/1` function using regex or `String.split`. Edge cases
  multiplied: values containing spaces broke blackboard writes, file paths
  with special characters broke pager opens.
- **No structured data in responses.** Bash returned `"4"` — was that stdout,
  an exit code, or an error message? The agent had to guess from context. The
  pager returned `"opened:pager_0:142 lines"` and the agent had to parse out
  the session ID with string manipulation.
- **`receive` bindings were lossy.** When services started returning richer
  information, agents needed both a human-readable summary (for interpolation
  into frames) and the full structured data (for extracting fields like
  `reply_to`). A single string couldn't serve both purposes.
- **Tracing and debugging was harder.** String messages in trace output
  required knowing each service's protocol to interpret. JSON objects are
  self-describing.
- **No path to richer content.** Strings can only carry text. Future features
  like image attachments, binary data, or multi-part messages would require
  inventing an encoding scheme on top of strings — effectively reinventing
  structured messages poorly.

### What replaced it

All messages are JSON objects (Elixir maps). The `msg` field in send ops is
always a map. Services pattern-match on map keys instead of parsing strings:

```json
{"op": "send", "mailbox": "bash", "msg": {"command": "ls -la"}}
{"op": "send", "mailbox": "blackboard", "msg": {"action": "write", "key": "k", "value": "v"}}
{"op": "send", "mailbox": "pager", "msg": {"action": "open", "path": "/etc/hosts"}}
```

The `"text"` key convention provides the human-readable summary:
- `${_msg}` / `${dest}` gets the `"text"` field (or `Jason.encode!` if absent)
- `${_payload}` / `${dest_payload}` gets the full JSON string

This gives agents clean values for interpolation (`${roll}` = `"4"`) while
preserving structured access when needed (`${roll_payload}` =
`{"text":"4","output":"4","exit_code":0}`).

## MessagesQueue as Runtime Message Log

**Introduced:** Stage 5b (Well-known services)
**Removed:** Stage 15 (Hardening pass — push calls removed from runtime path)

Each agent got a per-agent `MessagesQueue` GenServer that recorded every
received message as a `{content, source}` tuple. The `push` call ran on
every `receive` op and every inter-cycle message wait. The queue was intended
as a message history that agents could query for context or replay.

### Why it didn't work

- **Write-only.** `push` was called on every message, but `pop` was never
  called in runtime code. The queue accumulated data that nothing read.
- **Unbounded growth.** Long-lived agents (idle daemons, grind workers)
  accumulated every message they ever received. No eviction, no cap.
- **Redundant with bindings.** The binding system (`${_msg}`, `${dest}`,
  `${_payload}`) already gives agents access to message content. The queue
  duplicated this data in a less accessible form (GenServer state vs.
  interpolation-ready bindings).
- **No consumer path.** There was no op or service protocol for agents to
  query their own message history. Building one would have required a new
  op or a well-known service, both adding complexity for a feature no
  prompt pattern needed.

### What replaced it

Nothing — the runtime path simply stopped writing to it. The
`MessagesQueue` module and its GenServer lifecycle are retained because
the smoke test suite uses `push`/`pop`/`to_list` for unit assertions
about the module itself.
