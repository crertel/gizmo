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
- [ ] Streaming support (optional, can defer)

## Stage 2: Structured Output (replaces text Parser)

The LLM returns structured JSON via a forced tool call (`eval_response`),
eliminating the need for a text parser. The `eval_response` tool schema
defines the ops array and frames array directly.

- [x] `eval_response` tool schema with ops (send/receive/fork/join) and frames
- [x] Anthropic: forced via `tool_choice: {type: "tool", name: "eval_response"}`
- [x] OpenAI: forced via `response_format: {type: "json_schema", ...}`
- [x] Normalized to Elixir tuples: `{:send, mailbox, msg}`, `:receive`, etc.
- [x] Validation of op fields (`validate_op/1` — send requires mailbox + msg, fork requires n + frames, etc.)

## Stage 3: Interpolation

Resolve `$n` and `${name}` references in text.

- [x] `$n` positional resolution against an args list
- [x] `${name}` named resolution against a key-value map
- [x] Escaping (`$$` for literal `$`)
- [x] Apply interpolation to frame text and message content (`interpolate_response/4`)
- [x] Unit tests (in-process smoke tests via `--test`)

## Stage 4: Mailbox Router

Central message routing registry.

- [x] Elixir Registry-based router: register(mailbox_id, pid), lookup(mailbox_id)
- [x] `route(mailbox_id, message)` — deliver message to registered PID
- [x] Mailbox ID generation (`generate_id/1`, monotonic integer with prefix)
- [x] Error handling for unregistered mailbox IDs

## Stage 5: Well-Known Services

Implement the service processes that back the well-known mailboxes.

### 5a: Args Stack
- [x] GenServer holding a list
- [x] Handle `{push, value}`, `{peek, n}`, `{pop}`
- [x] Registered in mailbox router

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
- [ ] Timeout handling for long-running commands

### 5e: Human Adapter
- [x] Two GenServers: `Human` (output) and `HumanInput` (input)
- [x] Receive message from agent → print to terminal
- [x] Read user input → send to agent's mailbox
- [ ] Later: swap IO for Phoenix channel without changing the agent

## Stage 6: Agent Process (The Core)

The GenServer that runs the eval loop.

- [x] State: mailbox_id, parent, chat_fn, verbose, receive_timeout, args_stack, msgs_queue
- [x] Boot frame loaded on init
- [x] Eval loop implementation:
  - Concatenate context stack as system prompt
  - Call LLM client
  - Interpolate response
  - Execute ops sequentially
  - Push replacement frames
  - Loop
- [x] `send` op: interpolate msg, route via mailbox router
- [x] `receive` op: block until message arrives, push to messages queue + args stack
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

## Stage 8: Fork and Join

Multi-process support.

- [x] `fork` op: spawn child with `spawn_link` (not yet DynamicSupervisor)
- [x] Register child mailbox in router
- [x] Push child mailbox ID onto parent's args
- [x] `join` op: send message to parent mailbox, terminate self
- [x] Process.monitor for unexpected child death → notify parent
- [x] Test: parent forks child, child does work, joins back (smoke test)

## Stage 9: Supervision and Error Recovery

Production-grade process management.

- [ ] Static supervisor for service processes (one_for_one)
- [ ] DynamicSupervisor for agent processes (fork currently uses spawn_link)
- [ ] Exception mailbox service
- [ ] Supervisor service: receives error reports, can spawn replacement agents
- [ ] Restart strategies and backoff
- [ ] Test: kill a service, verify it restarts; kill an agent, verify supervisor is notified

## Stage 10: Polish and Hardening

- [ ] Logging: structured logs for eval cycles, message routing, errors
- [ ] Telemetry: eval cycle count, LLM latency, message throughput
- [ ] Boot frame templating: parameterize mailbox registry in boot frames
- [ ] Config: LLM model selection, timeouts, retry counts
- [ ] Documentation: module docs, usage examples

## Deferred / Future

These are explicitly out of scope for the initial build but noted for later:

- Frame tagging (code/quote, security taint tracking)
- Selective receive (pattern matching on messages)
- Context summarization service
- Persistence (durable stacks/mailboxes across restarts)
- Args-on-fork semantics (copy vs. fresh)
- Nested boot frames / sandboxing
- Phoenix LiveView human adapter
- Prompt injection defense
