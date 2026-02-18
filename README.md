# Gizmo

Gizmo is a minimal runtime for LLM agents modeled on process calculus and the
BEAM. An agent is a process with a context stack, a mailbox, and four syscalls
(`send`, `receive`, `fork`, `join`). Everything else — tool use, memory,
multi-agent coordination, human interaction — is built on top as mailbox-backed
services.

The entire runtime is a single Elixir script (`gizmo.exs`). You write a plain
text "boot frame" describing what the agent should do, and Gizmo runs an eval
loop: prompt the LLM, execute the returned ops, replace the context stack with
the returned frames, repeat.

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
| `-v` | Verbose mode — shows ops, frames, args each cycle |
| `--thinking` | Enable extended thinking |
| `--init <file>` | Generate a starter boot frame file |

### Example

```bash
# Run the hello-world test frame
elixir gizmo.exs test/01_hello.txt

# Run the echo-bot loop in verbose mode
elixir gizmo.exs -v test/05_loop.txt
```

## Project structure

```
gizmo.exs          # The entire runtime (single-file script)
flake.nix          # Nix dev shell
test/              # Example boot frames
  01_hello.txt     # One-shot greeter
  02_bash.txt      # Shell command execution
  03_blackboard.txt # Key-value store usage
  04_fork.txt      # Process forking
  05_loop.txt      # Echo-bot loop
  06_chat.txt      # Multi-turn chatbot
ARCHITECTURE.md    # Runtime design and process model
DEVELOPMENT.md     # Development stages and roadmap
PROMPTING.md       # Guide for writing boot frames
```

## Further reading

- [ARCHITECTURE.md](ARCHITECTURE.md) — process model, syscalls, message routing, supervision tree
- [PROMPTING.md](PROMPTING.md) — how to write boot frames for Gizmo agents
- [DEVELOPMENT.md](DEVELOPMENT.md) — development stages and roadmap

## License

See repository for license details.
