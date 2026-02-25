# Gizmo

Gizmo is a minimal runtime for LLM agents modeled on process calculus and the
BEAM. An agent is a process with a context stack, a mailbox, and four ops
(`send`, `receive`, `spawn`, `trap`). Everything else — tool use, memory,
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
| `--init <file>` | Generate a starter boot frame file |
| `--max-cycles N` | Max eval cycles before terminating (default: 50, 0 = unlimited) |
| `--idle` | Idle (restore boot frame) when frames exhaust instead of terminating |
| `--boot <file>` | Separate boot frame file (used for idle recovery) |
| `--grind` | Hot-loop mode (no inter-cycle message wait) |
| `--watchdog <ms>` | Periodic tick messages at given interval |

### Positional arguments

Without `--boot`, the first positional file is the boot frame and any additional
files are stacked on top. With `--boot`, the boot file is used for idle recovery
and all positional files are task frames.

### Signal handling

- `Ctrl+\` (SIGQUIT) or `kill <pid>` (SIGTERM) cleanly stops the runtime.
- Double `Ctrl+C` is the hard kill.

### Example

```bash
# Run the hello-world test frame (one-shot, terminates cleanly)
elixir gizmo.exs test/01_hello.txt

# Run the echo-bot loop in verbose mode
elixir gizmo.exs -v test/05_loop.txt

# Multi-file stack with separate boot frame
elixir gizmo.exs --boot sys.txt task.txt

# Limit eval cycles
elixir gizmo.exs --max-cycles 10 task.txt
```

## Project structure

```
gizmo.exs          # The entire runtime (single-file script)
flake.nix          # Nix dev shell
test/              # Example boot frames
  01_hello.txt     # One-shot greeter
  02_bash.txt      # Shell command execution
  03_blackboard.txt # Key-value store usage
  04_fork.txt      # Process spawning
  05_loop.txt      # Echo-bot loop
  06_chat.txt      # Multi-turn chatbot
  07_reaper.txt    # Reaper service (parent kills child)
  08_lucky_number.txt # Grind child + reaper (dice game)
  09_lucky_number_idle.txt # Idle child + trap (dice game variant)
ARCHITECTURE.md    # Runtime design and process model
DEVELOPMENT.md     # Development stages and roadmap
PROMPTING.md       # Guide for writing boot frames
```

## Further reading

- [ARCHITECTURE.md](ARCHITECTURE.md) — process model, ops, message routing, supervision tree
- [PROMPTING.md](PROMPTING.md) — how to write boot frames for Gizmo agents
- [DEVELOPMENT.md](DEVELOPMENT.md) — development stages and roadmap

## License

Apache License 2.0. See [LICENSE](LICENSE) for details.
