# Gizmo

Gizmo is a minimal runtime for LLM agents modeled on process calculus and the
BEAM. An agent is a process with a context stack, a mailbox, and three ops
(`send`, `spawn`, `trap`). Everything else — tool use, memory,
multi-agent coordination, human interaction — is built on top as mailbox-backed
services.

The entire runtime is a single Elixir script (`gizmo.exs`). You write a plain
text "boot frame" describing what the agent should do, and Gizmo runs an eval
loop: prompt the LLM, execute the returned ops, replace the context stack with
the returned frames, repeat.


> [!IMPORTANT]
> Being what this is, there is *extremely heavy* use of Claude and other AI tooling. Max vibes.
> This is also a research project and so it's extra messy (why else is it all just one script file? That's madness ordinarily.)
>
> So, if you aren't willing to deal with that, don't complain--just go elsewhere. - @crertel

## Prerequisites

- **Elixir 1.19+** / Erlang/OTP 28+
- An **Anthropic API key** (set as `ANTHROPIC_API_KEY` environment variable), or
  an OpenAI-compatible endpoint

## Installation

Clone the repo:

```bash
git clone git@github.com:crertel/gizmo.git
cd gizmo
```

### With Elixir installed directly

If you already have Elixir 1.19+ on your system, no further setup is needed.
Dependencies (`Req`) are fetched automatically via `Mix.install` on first run.

### With Nix (flake)

The repo includes a `flake.nix` that provides a dev shell with Elixir 1.19 and
Erlang/OTP 28:

```bash
nix develop
```

### On NixOS

Same as above — use the flake dev shell:

```bash
nix develop
```

Or add the flake to your project inputs and use its dev shell in your own
configuration. The flake targets `x86_64-linux` and pulls from `nixos-unstable`.

## Usage

Set your API key:

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
```

Generate a starter boot frame:

```bash
elixir gizmo.exs --init my_task.txt
```

Edit the task section in `my_task.txt`, then run it:

```bash
elixir gizmo.exs my_task.txt
```

### Flags

| Flag | Description |
|------|-------------|
| `-v` | Verbose mode — shows ops, frames, bindings each cycle |
| `--thinking` | Enable extended thinking |
| `--model <id>` | LLM model to use (default: env var or `claude-sonnet-4-20250514`) |
| `--init <file>` | Generate a starter boot frame file |
| `--max-cycles N` | Max eval cycles before terminating (default: 50, 0 = unlimited) |
| `--boot <file>` | Separate boot frame file (used for initial stack / named boot sections) |
| `--watchdog <ms>` | Periodic tick messages at given interval |
| `--name <id>` | Custom mailbox ID for the root agent |
| `--each` | Spawn one agent per positional file (instead of stacking) |
| `--runtime <file>` | Use a custom runtime preamble instead of the built-in one |
| `--dump-runtime <file>` | Write the built-in runtime preamble to a file for editing |
| `--dry-run` | Print the full initial prompt (runtime + frames) to stdout and exit |
| `--list-models` | List available models from configured backend(s) |
| `--test` | Run smoke tests, then exit |
| `--log-timings` | Show LLM call, cycle, and wall-clock timing per eval cycle |
| `--log-full-prompts` | Show full system prompt and user message each cycle |
| `--trace` | Emit NDJSON trace to stderr (silences logger) |
| `--trace-file <file>` | Emit NDJSON trace to file (silences logger) |
| `--trace-service` | Include service events in trace (bash, blackboard, watchdog, reaper) |
| `--trace-messages` | Include message routing events in trace |
| `--bash-timeout N` | Default bash command timeout in ms (default: 60000, 0 = none) |

### Positional arguments

Without `--boot`, the first positional file is the boot frame and any additional
files are stacked on top. With `--boot`, the boot file is used as the initial
stack root and all positional files are task frames. With `--each`, each
positional file becomes a separate independent agent.

### Signal handling

- `Ctrl+\` (SIGQUIT) or `kill <pid>` (SIGTERM) cleanly stops the runtime.
- Double `Ctrl+C` is the hard kill.

### Example

```bash
# Run the hello-world test frame (one-shot, terminates cleanly)
elixir gizmo.exs test/tasks/01_hello.txt

# Run the echo-bot loop in verbose mode
elixir gizmo.exs -v test/tasks/05_loop.txt

# Multi-file stack with separate boot frame
elixir gizmo.exs --boot sys.txt task.txt

# Named root agent
elixir gizmo.exs --name mybot task.txt

# One agent per file
elixir gizmo.exs --each a.txt b.txt

# Each agent gets sys.txt as boot frame
elixir gizmo.exs --each --boot sys.txt a.txt b.txt

# Limit eval cycles
elixir gizmo.exs --max-cycles 10 task.txt
```

## Project structure

```
gizmo.exs              # The entire runtime (single-file script)
flake.nix              # Nix dev shell
test/
  runtime/             # ExUnit runtime and service tests
  tasks/               # Example boot frames / integration-style prompt corpus
    01_hello.txt       # One-shot greeter
    02_bash.txt        # Shell command execution
    03_blackboard.txt  # Key-value store usage
    04_fork.txt        # Process spawning
    05_loop.txt        # Echo-bot loop
    06_chat.txt        # Multi-turn chatbot
    07_reaper.txt      # Reaper service (parent kills child)
    09_lucky_number_idle.txt # Lease-renewed child + exhaustion trap (dice game variant)
    10_marketplace.txt # Disowned peers + blackboard discovery (marketplace)
    11a_named_spawn.txt # Named child spawn (custom mailbox ID)
    11b_each_hello.txt # Per-file agent for --each mode
    12_pager.txt       # Interactive file pager (factory + session pattern)
    13_eval.txt        # Eval calculator (math assistant)
    14_batch.txt       # Batch system profiler (parallel info gathering)
    15_factory.txt     # Factory service demo (runtime counter)
    16_toolmaker.txt   # Chatbot with memory and runtime tool creation
    17_animal_research.txt # Single-agent Wikipedia animal research
    18_animal_expedition.txt # Multi-child expedition with factory wiki tool
    19_contemplative_agent.txt # 7-cycle lifecycle: create, explore, reflect, exit
    20_curious_explorer.txt # Autonomous infinite explorer (VM, runs until killed)
    21_migration.txt   # Live migration walkthrough
    22_webserver.txt   # Message-driven webserver workflow
    23_nixos_rebuild.txt # NixOS rebuild orchestration
ARCHITECTURE.md        # Runtime design and process model
DEVELOPMENT.md         # Development stages and roadmap
PROMPTING.md           # Guide for writing boot frames
FUTURE_WORK.md         # Ideas for future development
DEAD_ENDS.md           # Approaches tried and abandoned
```

## Further reading

- [ARCHITECTURE.md](ARCHITECTURE.md) — process model, ops, message routing, supervision tree
- [PROMPTING.md](PROMPTING.md) — how to write boot frames for Gizmo agents
- [DEVELOPMENT.md](DEVELOPMENT.md) — development stages and roadmap

## License

Apache License 2.0. See [LICENSE](LICENSE) for details.
