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
- [ ] Handle API errors, rate limits, retries
- [ ] Streaming support (optional, can defer)

## Stage 2: Structured Output (replaces text Parser)

The LLM returns structured JSON via a forced tool call (`eval_response`),
eliminating the need for a text parser. The `eval_response` tool schema
defines the ops array and frames array directly.

- [x] `eval_response` tool schema with ops (send/receive/fork/join) and frames
- [x] Anthropic: forced via `tool_choice: {type: "tool", name: "eval_response"}`
- [x] OpenAI: forced via `response_format: {type: "json_schema", ...}`
- [x] Normalized to Elixir tuples: `{:send, mailbox, msg}`, `:receive`, etc.
- [ ] Validation of op fields (e.g. send requires mailbox + msg)

## Stage 3: Interpolation

Resolve `$n` and `${name}` references in text.

- [x] `$n` positional resolution against an args list
- [x] `${name}` named resolution against a key-value map
- [x] Escaping (`$$` for literal `$`)
- [ ] Apply interpolation to frame text and message content
- [ ] Unit tests

## Stage 4: Mailbox Router

Central message routing registry.

- [ ] Elixir Registry-based router: register(mailbox_id, pid), lookup(mailbox_id)
- [ ] `route(mailbox_id, message)` — deliver message to registered PID
- [ ] Mailbox ID generation (e.g., `mb_001`, `mb_002`, ...)
- [ ] Error handling for unregistered mailbox IDs

## Stage 5: Well-Known Services

Implement the service processes that back the well-known mailboxes.

### 5a: Args Stack
- [ ] GenServer holding a list
- [ ] Handle `{push, value}`, `{peek, n}`, `{pop}`, `{pop, n}`
- [ ] Registered in mailbox router

### 5b: Messages Queue
- [ ] GenServer holding a `:queue`
- [ ] Stores `{content, source}` tuples
- [ ] Registered in mailbox router

### 5c: Blackboard
- [ ] GenServer or ETS-backed key-value store
- [ ] Handle `{read, key}`, `{write, key, value}`
- [ ] Registered in mailbox router

### 5d: Bash Adapter
- [ ] GenServer that receives command strings
- [ ] Execute via `System.cmd` or `Port`
- [ ] Send stdout/stderr back to caller's mailbox
- [ ] Timeout handling for long-running commands

### 5e: Human Adapter
- [ ] GenServer bridging IO.gets/IO.puts to a mailbox
- [ ] Receive message from agent → print to terminal
- [ ] Read user input → send to agent's mailbox
- [ ] Later: swap IO for Phoenix channel without changing the agent

## Stage 6: Agent Process (The Core)

The GenServer that runs the eval loop.

- [ ] State: context_stack, mailbox_id, parent_id
- [ ] Boot frame loaded on init
- [ ] Eval loop implementation:
  - Pop top frame
  - Concatenate remaining stack bottom-up
  - Call LLM client (prefix = concat, input = popped frame)
  - Parse response
  - Execute ops sequentially
  - Push replacement frames
  - Loop
- [ ] `send` op: interpolate msg, route via mailbox router
- [ ] `receive` op: block until message arrives, push to messages queue + args stack
- [ ] Idle behavior: boot frame self-replaces, checks mailbox
- [ ] Error handling: retry on parse failure (3x), then exception mailbox

## Stage 7: End-to-End Single Agent

Wire everything together and run the addition example from the design doc.

- [ ] Boot an agent process with a boot frame and a task frame
- [ ] Agent talks to human adapter (ask for two numbers)
- [ ] Agent talks to bash adapter (compute sum)
- [ ] Agent reports result to human
- [ ] Verify args stack, messages queue, and blackboard work correctly
- [ ] Manual testing, then write integration test

## Stage 8: Fork and Join

Multi-process support.

- [ ] `fork` op: DynamicSupervisor.start_child with copied/modified stack
- [ ] Register child mailbox in router
- [ ] Push child mailbox ID onto parent's args
- [ ] `join` op: send message to parent mailbox, terminate self
- [ ] Process.monitor for unexpected child death → notify parent
- [ ] Test: parent forks child, child does work, joins back

## Stage 9: Supervision and Error Recovery

Production-grade process management.

- [ ] Static supervisor for service processes (one_for_one)
- [ ] DynamicSupervisor for agent processes
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
