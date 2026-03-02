# sub-claude

A **session-oriented pool** of persistent Claude TUI slots backed by tmux. Solves a fundamental problem: launching a new `claude` process while another Claude session has a Bash tool call in flight silently destroys that call's output. sub-claude pre-starts sessions and reuses them — `start`, `followup`, and `wait` never launch new `claude` processes.

## Quick Start

```bash
# Install
./install.sh

# Initialize a pool (5 slots by default)
sub-claude pool init

# Fire-and-forget
id=$(sub-claude start "refactor auth module")

# Blocking — wait for result
result=$(sub-claude -v response start "summarize this file" --block)

# Multi-turn
id=$(sub-claude start "analyze the codebase")
sub-claude wait "$id"
sub-claude followup "$id" "now suggest improvements" --block

# Parallel work
id1=$(sub-claude start "task one")
id2=$(sub-claude start "task two")
sub-claude wait  # waits for first child to finish
sub-claude wait  # waits for the next one
```

## Installation

### Claude Code Plugin (recommended)

Installs the skill and hooks — Claude learns how to use sub-claude automatically.

```bash
# Per-session (development/testing):
claude --plugin-dir /path/to/sub-claude

# Persistent (once a marketplace is published):
# Inside Claude Code, run:
#   /plugin marketplace add EliasSchlie/claude-plugins
#   /plugin install sub-claude@elias-tools
```

### CLI

The plugin handles Claude Code integration. The CLI binary needs a separate install:

```bash
git clone https://github.com/EliasSchlie/sub-claude.git
cd sub-claude
./install.sh
```

This installs to `~/.local/bin/` and `~/.local/lib/`. Use `--prefix /usr/local` for system-wide install.

### Prerequisites

- **bash** >= 4.x
- **tmux**
- **jq**
- **claude** CLI (installed and authenticated)

## CLI Reference

```
sub-claude [-v response|conversation|full|raw] <command> [args]

# Session commands
sub-claude start "prompt" [--block]
sub-claude followup <id> "prompt" [--block]
sub-claude input <id> "text"
sub-claude key <id> Escape|Enter|Up|...
sub-claude capture <id>
sub-claude result <id>
sub-claude wait [<id>] [--quiet]
sub-claude pin <id> [duration]
sub-claude unpin <id>
sub-claude status <id>
sub-claude list [--tree | --all]
sub-claude stop <id> | --tree | --all
sub-claude cancel <id>
sub-claude clean <id> [--force | --force-all]

# Pool management
sub-claude pool init [--size N]
sub-claude pool stop
sub-claude pool status
sub-claude pool resize N

# Debug
sub-claude attach <id>
sub-claude uuid <id>
```

## Development

```bash
# Run from source (no install needed)
./dev.sh run pool status

# Run tests
./dev.sh test unit          # unit tests (fast, mocked)
./dev.sh test integration   # integration tests (real tmux, mock claude)
./dev.sh test live          # live tests (real Claude, burns tokens)
./dev.sh test all           # unit + integration
```

### Test prerequisites

- [bats-core](https://github.com/bats-core/bats-core)
- tmux, jq (for integration tests)
- claude CLI (for live tests only)

## Documentation

- [Architecture](docs/architecture.md) — implementation spec, state machines, infrastructure
- [Output](docs/output.md) — JSONL extraction, terminal capture, verbosity modes
- [Usage Guide](docs/USAGE.md) — comprehensive CLI reference with examples
- [Transcript Collision](docs/transcript-collision.md) — the problem sub-claude solves

## Uninstall

```bash
./install.sh --uninstall
```

## License

MIT
