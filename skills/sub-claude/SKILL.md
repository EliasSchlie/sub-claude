---
name: sub-claude
description: Use when needing to run Claude instances in parallel or in sequence — fire-and-forget tasks, multi-turn conversations, or any headless Claude work.
---

# sub-claude

A **session-oriented pool** of persistent Claude TUI slots backed by tmux. Solves a fundamental problem: launching a new `claude` process while another Claude session has a Bash tool call in flight silently destroys that call's output. sub-claude pre-starts sessions and reuses them — `start`, `followup`, and `wait` never launch new `claude` processes.

**Not claude-spawn:** pool sessions are persistent TUIs (not `claude -p`), support multi-turn conversation via `followup`, and never launch new `claude` processes.

**Output parsing:** Use `-v` / `--verbosity` to filter output. Levels: `response` (final model answer only), `conversation` (all prompts + responses), `full` (everything minus TUI chrome), `raw` (default, unfiltered). Example: `sub-claude -v response wait "$id"`

## Quick Start

```bash
# Fire-and-forget
id=$(sub-claude start "refactor auth module")

# Blocking — wait for result (parsed to just the response)
result=$(sub-claude -v response start "summarize this file" --block)

# Multi-turn
id=$(sub-claude start "analyze the codebase")
sub-claude wait "$id"
sub-claude followup "$id" "now suggest improvements" --block

# See what a running session is doing
sub-claude capture "$id"

# Parallel work
id1=$(sub-claude start "task one")
id2=$(sub-claude start "task two")
sub-claude wait "$id1"
sub-claude wait "$id2"

# Cross-project: manage a pool in another directory
sub-claude -C ~/obsidian pool init --size 3
sub-claude -C ~/obsidian start "organize notes"
sub-claude -C ~/obsidian pool status
```

## CLI

Run `sub-claude --help` for full CLI reference.

## Output Contract

| Command | stdout | stderr | blocks? |
|---------|--------|--------|---------|
| `start` | job ID | — | no |
| `start --block` | terminal output | job ID + warnings | yes (unless queue pressure) |
| `followup` | job ID | — | no |
| `followup --block` | terminal output | job ID + warnings | yes (unless queue pressure) |
| `capture` | live terminal or snapshot | offload note (if applicable) | no |
| `result` | terminal output | — | no (errors if running) |
| `wait <id>` | terminal output | warnings | yes |
| `wait` (no ID) | result of first child to finish | `--- <id> ---` header | yes |

## Session Lifecycle

```
queued → processing → finished(idle) → finished(offloaded)
             │
             └→ error (slot crashed)
```

- **queued** — waiting for a slot (all slots busy)
- **processing** — Claude is working on it in a slot
- **finished(idle)** — done, session still loaded in a slot, ready for `followup`
- **finished(offloaded)** — slot was reclaimed; terminal snapshot stored, session can be resumed

## Multi-Turn Conversations

`followup` resumes a finished session — conversation history is preserved.

- Only works on **finished** sessions. Errors if still processing (use `wait` first).
- If the session was offloaded, a slot is allocated and resumed automatically.
- Reuses the existing job ID (same session, same conversation).

## Blocking vs Non-Blocking

**Non-blocking (default):** `start` prints the ID and returns immediately. Use `wait` or `capture` to observe progress.

**`--block`:** waits inline, prints terminal output to stdout. ID goes to stderr. Under queue pressure, `--block` degrades to non-blocking — see [pool-management.md](pool-management.md#queue-pressure).

## Best Practices

**Prefer fire-and-forget + explicit wait** over `--block` for parallel work.

**Use `followup` for multi-turn, not `input`.** `input` is for raw terminal interaction (menus, interactive prompts).

**Clean completed sessions** to free slots: `sub-claude clean --completed`

**Auto-init:** if no pool exists when you call `start`, it initializes one automatically (5 slots). Prefer explicit `pool init --size N` with a larger size before starting work.

**Always overprovision.** Sub-agents, other Claude instances, and hooks all consume slots. A pool that looks big enough at launch saturates quickly once nested work kicks in.

## Sub-Skills

| Situation | File |
|-----------|------|
| Interactive key sequences, pinning, multi-instance isolation | [interactive-sessions.md](interactive-sessions.md) |
| Pool setup, resizing, queue pressure, environment variables | [pool-management.md](pool-management.md) |
| Reusable custom agents via command scripts | [custom-agents.md](custom-agents.md) |
| `sub-claude` not found, install/update/uninstall | [installation.md](installation.md) |

## Feedback & Issues

**File bugs and feature requests** at [github.com/EliasSchlie/sub-claude/issues](https://github.com/EliasSchlie/sub-claude/issues).