# Gizmo Development Stages

## Stage 0: Project Skeleton

Set up the single-file script and basic infrastructure.

- [x] Create `gizmo.exs` with `Mix.install([{:req, "~> 0.5"}])` at the top
- [x] Configure API key management (read `ANTHROPIC_API_KEY` from env)
- [x] Verify nix devshell runs `elixir gizmo.exs` cleanly

## Stage 1: LLM Client

Get a working call to Claude and back, returning structured JSON.

- [x] `Gizmo.LLM` behaviour with `eval_tool` schema (ops + frames)
- [x] `Gizmo.LLM.Anthropic` — Claude Messages API via Req, forced tool_use
- [x] `Gizmo.LLM.OpenAI` — OpenAI-compatible client via structured outputs (json_schema)
- [x] JSON encoding/decoding via Req (`:json` option)
- [x] Both clients normalize response to `{:ok, %{ops: [...], frames: [...]}}` tuples
- [x] Handle API errors, rate limits, retries (`Gizmo.LLM.Retry`, exponential backoff on 429/5xx)
- [x] ~Streaming support~ — removed, see DEAD_ENDS.md

## Stage 2: Structured Output (replaces text Parser)

The LLM returns structured JSON via a forced tool call (`eval_response`),
eliminating the need for a text parser. The `eval_response` tool schema
defines the ops array and frames array directly.

- [x] `eval_response` tool schema with ops (send/receive/spawn/trap) and frames
- [x] Anthropic: forced via `tool_choice: {type: "tool", name: "eval_response"}`
- [x] OpenAI: forced via `response_format: {type: "json_schema", ...}`
- [x] Normalized to Elixir tuples: `{:send, mailbox, msg}`, `:receive`, etc.
- [x] Validation of op fields (`validate_op/1` — send requires mailbox + msg, spawn requires frames + dest, etc.)

## Stage 3: Interpolation

Resolve `${name}` references in text.

- [x] `${name}` named resolution against a bindings map (populated by `receive(dest)` and `spawn(dest)`)
- [x] Escaping (`$$` for literal `$`)
- [x] Apply interpolation to frame text and message content (`interpolate_response/3`)
- [x] Unit tests (in-process smoke tests via `--test`)
- Note: `$n` positional args stack was replaced by named bindings via `dest`

## Stage 4: Mailbox Router

Central message routing registry.

- [x] Elixir Registry-based router: register(mailbox_id, pid), lookup(mailbox_id)
- [x] `route(mailbox_id, message)` — deliver message to registered PID
- [x] Mailbox ID generation (`generate_id/1`, monotonic integer with prefix)
- [x] Error handling for unregistered mailbox IDs

## Stage 5: Well-Known Services

Implement the service processes that back the well-known mailboxes.

### 5a: Args Stack (removed)
- Replaced by named bindings via `dest` field on `receive` and `spawn` ops.
  Bindings are threaded through the eval loop as a plain map — no GenServer needed.

### 5b: Messages Queue
- [x] GenServer holding a `:queue`
- [x] Stores `{content, source}` tuples
- [x] Registered in mailbox router

### 5c: Blackboard
- [x] GenServer key-value store (plain map)
- [x] Handle `{read, key}`, `{write, key, value}` (plus string command protocol)
- [x] Registered in mailbox router

### 5d: Bash Adapter
- [x] GenServer that receives command strings
- [x] Execute via `System.cmd("sh", ["-c", cmd])`
- [x] Send stdout/stderr back to caller's mailbox
- [x] Timeout handling for long-running commands

### 5e: Human Adapter
- [x] Two GenServers: `Human` (output) and `HumanInput` (input)
- [x] Receive message from agent → print to terminal
- [x] Read user input → send to agent's mailbox
- [ ] Later: swap IO for Phoenix channel without changing the agent

## Stage 6: Agent Process (The Core)

The GenServer that runs the eval loop.

- [x] State: mailbox_id, parent, chat_fn, verbose, receive_timeout, msgs_queue (bindings threaded through eval_loop)
- [x] Boot frame loaded on init
- [x] Eval loop implementation:
  - Concatenate context stack as system prompt
  - Call LLM client
  - Interpolate response
  - Execute ops sequentially
  - Push replacement frames
  - Loop
- [x] `send` op: interpolate msg, route via mailbox router
- [x] `receive` op: block until message arrives, store in bindings[dest] + messages queue
- [x] Idle behavior: boot frame self-replaces, checks mailbox
- [x] Error handling: retry on LLM failure (3x)
- [x] Exception mailbox on retry exhaustion (routes to "exception" service and terminates)

## Stage 7: End-to-End Single Agent

Wire everything together and run the addition example from the design doc.

- [x] Boot an agent process with a boot frame and a task frame
- [x] Agent talks to human adapter
- [x] Agent talks to bash adapter
- [x] Agent reports result to human
- [x] Verify args stack, messages queue, and blackboard work correctly (smoke tests)
- [x] Manual testing via test frames (01–06), smoke tests via `--test`

## Stage 8: Spawn (formerly Fork and Join)

Multi-process support.

- [x] `spawn` op: create child process with given frames
- [x] Register child mailbox in router
- [x] Store child mailbox ID in binding `dest`
- [x] `_self` and `_parent` runtime bindings for agent identity
- [x] Termination: `send` to `${_parent}` + `frames: []` (no special op)
- [x] Process.monitor for unexpected child death → notify parent
- [x] Test: parent spawns child, child sends result, parent receives (smoke test)
- Note: `fork`/`join` ops removed — see DEAD_ENDS.md

## Stage 9: Supervision and Error Recovery

Production-grade process management.

- [x] `Gizmo.Supervision` — `one_for_one` supervisor for Registry + all services + `DynamicSupervisor`
- [x] `Gizmo.AgentSupervisor` (`DynamicSupervisor`) for agent processes with `:temporary` restart
- [x] `Gizmo.Agent.Wrapper` — `:proc_lib.start_link/3` bridge for OTP-compatible agent processes
- [x] Exception mailbox service (implemented in Stage 8, now supervised)
- [x] Supervisor service dropped — OTP supervision handles restarts; exception mailbox handles error reporting
- [x] Test: kill Blackboard, verify it restarts and re-registers
- [x] Test: agent exits cleanly under DynamicSupervisor, not restarted

## Stage 10: CLI Runtime Options

Configurable cycle limits, stack exhaustion behavior, multi-file frame stacks,
and signal handling.

- [x] `--max-cycles N` — configurable eval cycle limit (default 50, 0 = unlimited)
- [x] `--idle` — idle on empty frames instead of terminating (opt-in)
- [x] `--boot <file>` — separate boot frame from task frames
- [x] Multi-file positional args (stacked as frames)
- [x] `max_cycles` and `quit_on_exhaust` (idle mode) propagated to spawned children
- [x] SIGTERM and SIGQUIT signal traps for clean abort
- [x] Tests: max_cycles limit, unlimited mode, terminate-on-exhaust and idle mode

## Stage 11: Polish and Hardening

- [ ] Logging: structured logs for eval cycles, message routing, errors
- [x] ~Telemetry~ — removed, see DEAD_ENDS.md
- [x] ~Boot frame templating~ — removed, see DEAD_ENDS.md
- [x] ~Config: cycle limits, stack exhaustion~ — done in Stage 10
- [ ] Config: LLM model selection, timeouts, retry counts
- [ ] Documentation: module docs, usage examples

## Stage 12: Message-Driven Eval Loop with Trap Support

Replace the hot-grind eval loop with a message-driven model. Agents sleep
between cycles and wake on mailbox messages.

- [x] Add `trap` op to schema and validation (empty frames = clear trap)
- [x] ~`untrap` op~ — removed, `trap(pattern, [])` clears trap (see DEAD_ENDS.md)
- [x] Refactor `eval_loop/7` to `eval_loop/3` with loop map
- [x] Thread trap through `execute_ops`/`execute_op`
- [x] Add `grind` flag (opt-in hot-loop for worker agents)
- [x] Implement inter-cycle message wait (`maybe_wait_for_message`)
  - First cycle: `${_msg} = "init"`, `${_msg_source} = "runtime"`
  - Grind mode: no wait (preserves old behavior)
  - Default: block on `receive`, bind `${_msg}` / `${_msg_source}`
  - Trap match: bind `${_interrupt}` / `${_interrupt_source}`, prepend handler frames
- [x] Replace `fork`/`join` with `spawn` + `_self`/`_parent` bindings (see DEAD_ENDS.md)
- [x] Add `Gizmo.Services.Watchdog` — periodic tick messages to target mailbox
- [x] Update `runtime_prompt()` with message-driven model, trap, watchdog docs
- [x] CLI: `--grind`, `--watchdog <ms>` flags
- [x] Existing tests updated with `grind: true` to preserve behavior
- [x] New smoke tests: first cycle init, message-driven wake, trap fire, trap no-match, grind mode
- [x] Op set evolution: `send, receive, fork, join` → `send, receive, spawn, trap`

## Stage 13: Reaper Service

Agent lifecycle management via a well-known `reaper` service. Agents can
force-kill children lower in the supervision hierarchy by sending their
mailbox ID to the reaper.

- [x] Store parent mailbox ID in Mailbox Registry value (`Gizmo.Mailbox.register/2`)
- [x] `Gizmo.Services.Reaper` — well-known service that accepts kill requests
- [x] Ancestor check: walk parent chain from target to verify caller is ancestor
- [x] Kill via `Process.exit(pid, :shutdown)` — triggers existing child death monitor
- [x] Parent receives `child_died:` notification as usual (no special case)
- [x] Tests: parent kills child, sibling rejected (smoke tests in `--test`)
- [x] Test frame: `test/08_lucky_number.txt` — grind child rolls dice, parent reaps on 1

## Deferred / Future

These are explicitly out of scope for the initial build but noted for later:

- ~Selective receive~ — partially addressed by trap (Stage 12)
- Context summarization service
- Persistence (durable stacks/mailboxes across restarts)
- Nested boot frames / sandboxing
- Phoenix LiveView human adapter
- Prompt injection defense
