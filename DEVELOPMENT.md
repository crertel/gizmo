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

- [x] `eval_response` tool schema with ops (send/spawn/trap) and frames
- [x] Anthropic: forced via `tool_choice: {type: "tool", name: "eval_response"}`
- [x] OpenAI: forced via `response_format: {type: "json_schema", ...}`
- [x] Normalized to Elixir tuples: `{:send, mailbox, msg}`, `{:spawn, ...}`, `{:trap, ...}`
- [x] Validation of op fields (`validate_op/1` — send requires mailbox + msg, spawn requires frames + dest, etc.)

## Stage 3: Interpolation

Resolve `${name}` references in text.

- [x] `${name}` named resolution against a bindings map (populated by `spawn(dest)` and runtime bindings)
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
- Replaced by named bindings via `dest` field on the old `receive` op and on
  `spawn`.
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
- [ ] ~Swap IO for Phoenix channel~ — deferred, see Deferred / Future

## Stage 6: Agent Process (The Core, Historical Notes)

The GenServer that runs the eval loop.

- [x] Early state included mailbox identity, parent, chat fn, messages queue,
  and other runtime options. Later simplification removed `receive_timeout`.
- [x] Boot frame loaded on init
- [x] Eval loop implementation:
  - Concatenate context stack as system prompt
  - Call LLM client
  - Interpolate response
  - Execute ops sequentially
  - Push replacement frames
  - Loop
- [x] `send` op: interpolate msg, route via mailbox router
- [x] Early versions still had a `receive` op before the runtime collapsed to
  the current three-op model.
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
- [x] `disown` option: detach child from parent (no `_parent` binding, no death monitor)
- [x] Cross-lineage messaging: independent agents discover each other via blackboard
- [x] Test: parent spawns child, child sends result, parent receives (smoke test)
- [x] Test: disown spawn, cross-lineage messaging (smoke tests)
- [x] Test frame: `test/10_marketplace.txt` — disowned peers trade via blackboard
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

Configurable cycle limits, multi-file frame stacks, and signal handling.

- [x] `--max-cycles N` — configurable eval cycle limit (default 50, 0 = unlimited)
- [x] `--boot <file>` — separate boot frame from task frames
- [x] Multi-file positional args (stacked as frames)
- [x] SIGTERM and SIGQUIT signal traps for clean abort
- [x] Tests: max_cycles limit, unlimited mode, termination behavior

Later runtime evolution removed `--idle` / `quit_on_exhaust`. Persistence is
now explicit via per-turn `keep_alive`, with renewed empty-stack turns waking
through synthetic `stack_exhausted` messages.

## Stage 11: Polish and Hardening

- [x] Logging: structured logs for eval cycles, message routing, errors (`--trace-service`, `--trace-messages`)
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
- [x] Implement inter-cycle message wait (`maybe_wait_for_message`)
  - First cycle: `${_msg} = "init"`, `${_msg_source} = "runtime"`
  - Default: block on `receive`, bind `${_msg}` / `${_msg_source}`
  - Trap match: bind `${_interrupt}` / `${_interrupt_source}`, prepend handler frames
- [x] Replace `fork`/`join` with `spawn` + `_self`/`_parent` bindings (see DEAD_ENDS.md)
- [x] Add `Gizmo.Services.Watchdog` — periodic tick messages to target mailbox
- [x] Update `runtime_prompt()` with message-driven model, trap, watchdog docs
- [x] CLI: `--watchdog <ms>` flag
- [x] New smoke tests: first cycle init, message-driven wake, trap fire, trap no-match
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

## Stage 19: Remove `receive`, Remove Grind, Collapse to One Execution Model

Cut the experimental escape hatches and keep the runtime message-driven only.

- [x] Remove `receive` from the eval schema, validation, tracing, logging, and op execution
- [x] Remove grind from CLI, runtime state, spawn options, and migration snapshots
- [x] Convert runtime tests to self-message / natural wakeup patterns
- [x] Delete `gizmo_minimal.exs`
- [x] Record the outcome in `DEAD_ENDS.md`

## Stage 14: Agent Naming and Multi-Agent CLI

Human-readable agent IDs and per-file agent spawning from the command line.

- [x] `name` option on `spawn` op: custom mailbox ID for child agents
- [x] `validate_spawn_string/4` helper for string spawn options
- [x] Registration failure triggers op error recovery (name collision binds `_op_error`)
- [x] `--name <id>` CLI flag for root agent naming
- [x] `--each` CLI flag: spawn one agent per positional file
- [x] `--each` + `--boot`: each agent gets boot frame + its positional file
- [x] `--each` + `--name` mutual exclusion check
- [x] `setup_runtime/1` helper factored from `run/2` (shared by `run` and `run_each`)
- [x] `wait_all/1` for monitoring multiple agent exits
- [x] Runtime prompt updated with `name` option in spawn docs
- [x] Tests: parse name string/error, named spawn behavior, name collision recovery
- [x] Test frames: `test/11a_named_spawn.txt`, `test/11b_each_hello.txt`

## Stage 15: Hardening Pass

Runtime robustness improvements for LLM-generated payloads.

- [x] Op execution error recovery: `execute_ops` catches per-op failures, binds `_op_error`/`_pending_ops`, increments retries
- [x] `spawn` name collision recovered (was a hard crash, now binds error context)
- [x] `trap` invalid regex recovered (was a match error, now raises with descriptive message)
- [x] Bash service: validates `timeout` field (non-integer/negative falls back to default)
- [x] Watchdog service: validates `ms` field (non-integer/negative returns error message)
- [x] Pager service: validates `line` field in `goto` (unparseable strings fall back to line 1)
- [x] `MessagesQueue.push` calls removed from runtime path (write-only scaffolding; module retained for tests)

## Stage 16: Batch and Eval Services

Two new well-known services for agent productivity.

- [x] `Gizmo.Services.Batch` — fan-out parallel requests via `"batch"` mailbox
- [x] `Gizmo.Services.BatchCoordinator` — bare module spawned per batch request, collects responses
- [x] `Gizmo.Services.Eval` — evaluate Elixir expressions via `"eval"` mailbox with AST sandboxing
- [x] Supervision: both services added to `Gizmo.Supervision` children
- [x] Runtime prompt: `batch` and `eval` docs in well-known mailboxes section
- [x] Smoke tests: batch (parallel, partial failure, invalid) and eval (arithmetic, string, enum, forbidden modules, syntax/runtime/timeout errors)

## Stage 17: Factory Service

User-defined stateful services created at runtime via the `"factory"` mailbox.

- [x] `Gizmo.Services.Factory` — well-known service on `"factory"` mailbox; accepts create/destroy/list commands
- [x] `Gizmo.Services.FactoryWorker` — generic GenServer wrapper for user-defined arity-2 handler functions
- [x] `Gizmo.FactorySupervisor` — `DynamicSupervisor` for factory-spawned workers (`:one_for_one`)
- [x] Supervision tree: `FactorySupervisor` + `Factory` added to `Gizmo.Supervision` children
- [x] Worker lifecycle: create compiles handler code, registers mailbox; destroy terminates child, deregisters
- [x] Worker death monitoring: factory watches workers, cleans up on unexpected exit
- [x] Runtime prompt: `factory` docs in well-known mailboxes section (create/destroy/list protocol)
- [x] Smoke tests: create worker, send message, destroy, list, duplicate name rejection, destroy nonexistent
- [x] Test frame: `test/15_factory.txt` — counter service demo (create, increment, read, destroy)

## Stage 18: Live Runtime Migration

Blue-green deployment via Erlang distribution. An agent can snapshot all
runtime state, spawn a new BEAM, transfer state, and shut down the old node.

- [x] `--node` and `--cookie` CLI flags for Erlang distribution
- [x] `Node.start/2` in `setup_runtime/1` (short names or long names based on presence of `.`)
- [x] `chat_config` stored in agent state (backend, model, thinking) for serialization
- [x] `Gizmo.Migration.Snapshot` module — serialize/deserialize agents and services
- [x] Service snapshot callbacks: Blackboard (`:snapshot` / `{:restore, data}`), Watchdog, Factory (worker code + user_state), Bash (counter only — ports aren't migratable), MessagesQueue
- [x] Agent pause protocol: `{:migration_pause, reply_to, ref}` checked at top of `eval_loop_inner` and in `maybe_wait_for_message`
- [x] `Gizmo.Services.Migration` — `"migration"` mailbox, orchestrates outbound migration via `:peer`
- [x] `--accept-migration` CLI flag for inbound migration (starts supervision tree, waits for snapshot)
- [x] Blackboard restore: `handle_call({:restore, %{store: new_store}}, ...)`
- [x] Agent restore-mode startup: `eval_loop_restored/3` entry point, re-inject drained messages
- [x] Post-migration "migration complete" message to restored agents
- [x] Context stack frame labeling: `>>> CURRENT FRAME <<<` / `--- QUEUED FRAME N ---` (needed for reliable multi-frame prompts discovered during migration testing)
- [x] Test frame: `test/21_migration.txt` — writes to blackboard, triggers migration, verifies data survived on new node
- [x] QEMU VM integration: test runs via `gizmo-vm` wrapper with `--node` and `--cookie`

## Deferred / Future

These are explicitly out of scope for the initial build but noted for later:

- ~Selective receive~ — partially addressed by trap (Stage 12)
- Phoenix channel / LiveView human adapter
- Context summarization service
- Persistence (durable stacks/mailboxes across restarts)
- Nested boot frames / sandboxing
- Phoenix LiveView human adapter
- Prompt injection defense
