# Improvements to Backport

This document summarizes the main improvements made in Gizmo that are worth
backporting, at least thematically, to another LLM agent system. The goal is
not "copy this exact architecture." The goal is to preserve the design moves
that made the system simpler, more legible, and more reliable under real
agent behavior.

## 1. Shrink the core runtime aggressively

The biggest improvement was reducing the runtime to a very small execution
core:

- one eval loop
- three primitive ops: `send`, `spawn`, `trap`
- everything else exposed as ordinary mailbox-backed services

This matters because every extra built-in concept becomes another thing the
model has to reason about and another place for semantics to drift. Pushing
timers, shell, memory, batching, eval, migration, and custom tools into the
same message interface made the system more uniform.

What to backport:

- Prefer a tiny set of first-class agent actions.
- Make tools/services look the same as agents from the model's perspective.
- Remove special cases where possible.

Expected effect:

- less prompt surface area
- less runtime branching
- fewer mismatched mental models between runtime and LLM

## 2. Make the runtime fully message-driven

Another important improvement was converging on one execution model only:
agents wake on messages. There is no separate "autonomous mode" with distinct
semantics.

This removed a lot of ambiguity. If an agent wants future work, it must create
that future work explicitly by:

- sending to itself
- scheduling a timer/watchdog message
- waiting for another agent or service reply

What to backport:

- Collapse multiple execution modes into one message-driven model.
- Treat "continue later" as an explicit act, not an implicit runtime feature.
- Design prompts around request/response turns instead of hidden internal
  looping.

Expected effect:

- easier debugging
- cleaner causality
- fewer accidental infinite loops

## 3. Make liveness explicit with leases

Long-lived behavior got much better once persistence stopped being implicit.
In Gizmo, a worker survives only if it renews itself by sending to
`keep_alive` in that cycle.

That is a strong design choice and it paid off. It forces the model to state
when it intends to stay alive, instead of the runtime guessing.

What to backport:

- Replace implicit persistence/idle behavior with explicit lease renewal.
- Make the default lifecycle one-shot or short-lived.
- Require agents to justify their continued existence every turn.

Expected effect:

- dead agents die cleanly
- fewer orphan loops
- clearer distinction between one-shot tasks and resident workers

## 4. Tighten continuation semantics around exhaustion

One subtle improvement was handling "I want to stay alive, but I finished my
current stack" explicitly. In Gizmo, if an agent renews its lease and returns
`frames: []`, the runtime injects a synthetic `stack_exhausted` message so the
agent can rebuild work through normal message handling.

This is better than silently restoring old prompt state or inventing hidden
continuation behavior.

What to backport:

- When an agent exhausts its current plan, surface that as an explicit event.
- Let the agent decide how to rebuild work.
- Avoid magic prompt restoration.

Expected effect:

- cleaner long-running loops
- less spooky action from old context
- better alignment between agent intent and runtime behavior

## 5. Use exact-event, one-shot traps instead of fuzzy interrupts

Trap handling improved when it became:

- exact event match
- one-shot by default
- explicit re-registration required

This is a strong simplification. Many agent runtimes drift into vague
"interrupt" behavior where it is unclear what will wake what, how many times,
or with what priority. Exact one-shot traps make interrupts much easier to
reason about.

What to backport:

- Match interrupts/events by exact key unless there is a compelling reason not
  to.
- Auto-clear handlers after they fire.
- Make repeated listening an explicit choice by the agent.

Expected effect:

- fewer surprise wakeups
- less handler accumulation
- easier state reasoning in prompts and tests

## 6. Be strict about async boundaries

One recurring source of failure in LLM runtimes is muddled timing: the model
acts as if a tool response is available in the same turn that sent the tool
request. Gizmo improved reliability by making the boundary explicit:
interpolation happens before ops run, so service results only exist on the
next wakeup.

That rule shows up throughout the prompts and examples.

What to backport:

- Document the request/response boundary very bluntly.
- Teach continuation-frame patterns as the default.
- Avoid giving the model affordances that make same-turn response handling
  look plausible when it is not.

Expected effect:

- fewer race-shaped prompt bugs
- more reliable multi-turn tool use
- easier authoring of agent tasks

## 7. Turn prompt authoring into operational discipline

A lot of the real improvement was not just runtime code. It was better prompt
discipline for agent authors.

Examples of useful prompt conventions:

- explicitly state that messages are JSON objects
- explicitly state when a cycle must renew its lease
- separate setup frames from steady-state loop frames
- store control metadata in frame text when the next step needs it
- tell the model what not to do when there are known failure modes

This looks mundane, but it matters. Small prompt constraints eliminated a lot
of avoidable model confusion.

What to backport:

- Write a short prompting guide for runtime-specific patterns.
- Standardize recurring prompt idioms instead of rediscovering them per task.
- Encode known failure patterns directly in task prompts.

Expected effect:

- faster task authoring
- less variance across agents
- fewer regressions caused by "creative" prompt structure

## 8. Harden integration tasks so they test one thing at a time

The test/task corpus improved when it moved away from "interesting demos" and
toward narrower behavioral targets. Broad showcase prompts are useful for
demos, but they are poor regression tests because failures are hard to
localize.

The clearest example is tool-creation scenarios. A task that mixes persona,
memory, intent routing, tool synthesis, and arbitrary execution is much harder
to trust than a task that checks one crisp behavior.

What to backport:

- Split demo prompts from regression prompts.
- Prefer single-capability integration tasks.
- Make success/failure easy to attribute to one subsystem.

Expected effect:

- more stable evals
- faster debugging
- less time blaming the wrong layer

## 9. Add prompt-level constraints for known model failure modes

Some improvements were targeted directly at observed LLM mistakes rather than
runtime theory. Examples:

- reminding the model that handler replies must be maps, not keyword lists
- telling the model to act immediately on concrete tool requests
- carrying tool names explicitly through later frames
- warning against stale self-messages or wrong reply sources

These are not elegant abstractions. They are practical patches over repeated
failure modes, and they are worth backporting.

What to backport:

- Track common model mistakes in real tasks.
- Add narrow prompt constraints where those mistakes recur.
- Prefer explicitness over elegance when reliability is the goal.

Expected effect:

- better first-pass behavior
- less retry churn
- more dependable small-model performance

## 10. Document the mental model, not just the API

The architecture and prompting docs got better once they explained the model's
operating reality, not just command syntax. The useful questions were:

- What wakes an agent?
- What survives to the next cycle?
- When is a value actually available?
- What causes a worker to die?
- How do loops happen now that everything is message-driven?

That style of documentation is unusually important for LLM systems because the
"programmer" is partly the human and partly the model.

What to backport:

- Write docs around lifecycle, causality, and timing.
- Show canonical patterns, not just schemas.
- Keep examples tightly aligned with real runtime semantics.

Expected effect:

- fewer invalid prompts
- easier onboarding
- less accidental divergence between design and usage

## Priority order for another system

If another LLM system cannot copy everything, the best order is:

1. simplify the runtime core
2. unify execution around messages
3. make liveness explicit
4. tighten event/interrupt semantics
5. harden prompts and integration tasks around known failure modes

That sequence gives most of the benefit. The later improvements mostly become
easier once those foundations are in place.

## Short version

The broad theme is: make the agent runtime more explicit, more uniform, and
less magical.

The most valuable changes were not flashy capabilities. They were reductions:

- fewer primitives
- fewer hidden execution modes
- fewer implicit continuations
- fewer vague interrupt semantics
- fewer overstuffed tests

That reduction made the whole system easier for both humans and models to use
correctly.
