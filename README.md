# sub-claude

A **session-oriented pool** of persistent Claude Code sessions backed by tmux.

## The Problem

Running a `claude` command while another Claude session has a Bash tool call in flight **silently destroys that call's output**. This is a fundamental Claude Code limitation - the transcript-directory file watcher reacts to new sessions, breaking active ones. You can't reliably run parallel Claude work by spawning new `claude` processes.

## The Solution

sub-claude **pre-starts** Claude TUI sessions in tmux panes before any work begins. New conversations use `/clear`, session switches use `/resume` - all typed into existing sessions, no new processes ever launched.

The result: reliable parallel Claude work with fire-and-forget, blocking, and multi-turn patterns.

## Quick Start

```bash
# Install CLI
git clone https://github.com/EliasSchlie/sub-claude.git
cd sub-claude
./install.sh

# Initialize a pool (5 slots by default)
sub-claude pool init

# Fire-and-forget
id=$(sub-claude start "refactor auth module")

# Blocking - wait for result
result=$(sub-claude -v response start "summarize this file" --block)

# Multi-turn conversation
id=$(sub-claude start "analyze the codebase")
sub-claude wait "$id"
sub-claude followup "$id" "now suggest improvements" --block

# Parallel fan-out
id1=$(sub-claude start "task one")
id2=$(sub-claude start "task two")
sub-claude wait  # waits for first to finish
sub-claude wait  # waits for the next
```

## Installation

### Claude Code Plugin (recommended)

The plugin teaches Claude how to use sub-claude automatically via skills and hooks.

```bash
# Per-session (development/testing):
claude --plugin-dir /path/to/sub-claude

# Persistent (via marketplace):
# Inside Claude Code, run:
#   /plugin marketplace add EliasSchlie/claude-plugins
#   /plugin install sub-claude@elias-tools
```

### CLI Binary

The plugin handles Claude Code integration. The CLI binary needs a separate install:

```bash
git clone https://github.com/EliasSchlie/sub-claude.git
cd sub-claude
./install.sh          # copies to ~/.local/{bin,lib}
# or
./install.sh --link   # symlinks binary - updates via git pull, no reinstall
```

Use `--prefix /usr/local` for system-wide install.

### Prerequisites

- **bash** >= 4.x
- **tmux**
- **jq**
- **claude** CLI (installed and authenticated)

## Architecture

```
         Caller A              Caller B
            |                       |
      start "prompt"        followup $id "prompt"
            |                       |
            v                       v
    +------------------------------------------+
    |          sub-claude orchestrator          |
    |                                          |
    |  Queue (FIFO): [job-3, job-4, ...]       |
    |                                          |
    |  Session mapping:                        |
    |    ID a1b2c3d4 -> slot-0 (busy)          |
    |    ID e5f6a7b8 -> slot-1 (idle)          |
    |    ID c9d0e1f2 -> offloaded (snapshot)   |
    +-------------------+----------------------+
                        |
        +---------------+---------------+
        v                               v
Background watcher            Shared tmux server
(polls every 2s)              +-- slot-0  (busy)
- done detection              +-- slot-1  (idle)
- queue dispatch              +-- slot-2  (fresh)
- crash recovery              +-- slot-3  (fresh)
- pin expiry                  +-- slot-4  (fresh)
```

**Key concepts:**

- **Pool** - pre-started Claude TUI sessions in tmux panes, scoped per project
- **Slots** - individual tmux panes running persistent Claude sessions
- **Job IDs** - 8-char hex identifiers for tracking work across slots
- **Offloading** - idle sessions are snapshot-saved and their slots reused when all are busy
- **Queue** - excess work is queued FIFO and dispatched as slots free up
- **Watcher** - background process that monitors slots, dispatches jobs, and handles crash recovery

## CLI Reference

```
sub-claude [-v response|conversation|full|raw] [-C <dir>] <command> [args]

# Session commands
sub-claude start "prompt" [--block] [--timeout S]     # start a new job
sub-claude followup <id> "prompt" [--block]           # continue a conversation
sub-claude input <id> "text"                          # send raw text input
sub-claude key <id> Escape|Enter|Up|...               # send a keypress
sub-claude capture <id>                               # capture current terminal output
sub-claude result <id>                                # get the job result
sub-claude wait [<id>] [--quiet] [--timeout S]        # wait for completion
sub-claude pin <id> [duration]                        # prevent offloading (default: 120s)
sub-claude unpin <id>                                 # allow offloading again
sub-claude status <id>                                # check job status
sub-claude list [--tree | --all]                      # list jobs
sub-claude stop <id> | --tree | --all                 # stop jobs
sub-claude cancel <id>                                # cancel a queued job
sub-claude clean <id> [--force | --force-all]         # clean up finished jobs

# Pool management
sub-claude pool init [--size N] [--idle-timeout S] [--ttl S] [--pressure-threshold N]
sub-claude pool stop                                  # stop the pool
sub-claude pool status                                # show pool health
sub-claude pool resize N                              # change pool size
sub-claude pool list                                  # list all pools across projects
sub-claude pool destroy <hash> | --all                # tear down pools

# Custom commands
sub-claude run <name> [args...]                       # run a custom command script
sub-claude run --list                                 # list available commands

# Debug
sub-claude attach <id>                                # attach to a job's tmux pane
sub-claude uuid <id>                                  # show the Claude session UUID
```

### Output verbosity (`-v`)

| Level | What you get |
|-------|-------------|
| `raw` | Unfiltered terminal capture (default) |
| `response` | Final model answer only — stripped of prompts and TUI chrome |
| `conversation` | All prompts + responses |
| `full` | Everything except TUI chrome |

Use `response` when scripting: `result=$(sub-claude -v response start "summarize file" --block)`

Set a default: `export SUB_CLAUDE_VERBOSITY=response`

### Pool init options

| Flag | Default | Description |
|------|---------|-------------|
| `--size N` | 5 | Number of slots |
| `--idle-timeout S` | — | Offload a session after N seconds idle |
| `--ttl S` | — | Max lifetime per session before forced restart |
| `--pressure-threshold N` | size/2 | Queued jobs needed before `--block` degrades to non-blocking |

### Session lifecycle

```
queued → processing → finished(idle) → finished(offloaded)
              └→ error
```

- **queued** — waiting for a free slot
- **processing** — Claude is actively working
- **finished(idle)** — done; slot still loaded, ready for `followup`
- **finished(offloaded)** — slot was reclaimed; snapshot stored, auto-resumed on next `followup`

## Custom Commands

Create reusable workflows as shell scripts in `~/.sub-claude/commands/` (global) or `.sub-claude/commands/` (project-local). See [docs/custom-commands.md](docs/custom-commands.md) for details and examples.

## Development

```bash
# Run from source (no install needed)
./dev.sh run pool status

# Run tests
./dev.sh test unit          # unit tests (fast, mocked with bats)
./dev.sh test integration   # integration tests (real tmux, mock claude)
./dev.sh test live          # live tests (real Claude, burns tokens)
./dev.sh test all           # unit + integration
```

### Test Prerequisites

- [bats-core](https://github.com/bats-core/bats-core)
- tmux, jq (for integration tests)
- claude CLI (for live tests only)

## Documentation

- [Architecture](docs/architecture.md) - implementation spec, state machines, infrastructure
- [Output](docs/output.md) - JSONL extraction, terminal capture, verbosity modes
- [Usage Guide](docs/USAGE.md) - comprehensive CLI reference with examples
- [Custom Commands](docs/custom-commands.md) - reusable workflow scripts
- [Transcript Collision](docs/transcript-collision.md) - the underlying problem sub-claude solves

## Uninstall

```bash
./install.sh --uninstall
```

## License

[MIT](LICENSE)
