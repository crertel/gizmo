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

- `--quit-on-exhaust` — agents terminate on empty frames instead of idling.
- `--max-cycles N` — configurable cycle limit, with 0 meaning unlimited.
- Both options propagate to forked children.
