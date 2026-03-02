# claude-spawn: Bash tool output bug (transcript collision)

> **Historical context.** `claude-spawn` is superseded by [sub-claude](architecture.md), which avoids this bug entirely by pre-starting sessions in tmux panes instead of spawning new `claude` processes. This document is preserved as reference for the underlying Claude Code transcript collision issue, which still affects any workflow that launches `claude` from within an active session.

## Problem

`claude-spawn start "prompt" --block` produced zero visible output from the
Bash tool — not even `echo` statements printed before the spawn were visible.
Non-blocking mode worked fine; jobs completed and wrote correct results to disk.

## Root cause

When a spawned `claude -p` runs from the **same project root** as the parent
Claude Code session, it creates a JSONL transcript in the same
`~/.claude/projects/<hash>/` directory. Cursor's extension monitors that
directory — a new transcript file appearing there breaks the active Bash
tool's output collection, silently swallowing all buffered stdout/stderr.

### Evidence

| Spawned cwd | Transcript hash matches parent? | Bash tool output |
|-------------|--------------------------------|-----------------|
| project root | YES | ❌ lost |
| subdirectory (`config/`) | NO | ✅ visible |
| `/tmp` | NO | ✅ visible |
| job dir (`~/.claude-spawn/jobs/<id>/`) | NO | ✅ visible |

**Timing**: `sleep 0.1` after spawn → output visible (transcript not yet written).
`sleep 1` → output lost (transcript file exists, extension reacted).

**Controls**: detached `sleep 30` in background + parent `sleep 3` → ✅.
Detached `node -e "setTimeout(...)"` + parent `sleep 3` → ✅.
Only `claude -p` triggers the bug.

### Falsified hypotheses

| Theory | Why wrong |
|--------|-----------|
| Inherited pipe fds (0-1024) | Same detach code works with `sleep` child |
| Stop hook corrupting output | Jobs with pre-included suggestions also fail |
| SSE server reconnection | lsof monitoring shows no new SSE connections |
| Bash tool pty detection | `tty` confirms not a tty; isatty all false |
| Process group monitoring | setsid'd `sleep 10` works fine |
| High-numbered fds (>1024) | `/dev/fd/` shows only fds 0-4 |

## Fix

Run spawned `claude -p` from the **job directory** (`~/.claude-spawn/jobs/<id>/`)
instead of the project root. The transcript goes to a different project hash,
avoiding the collision. Original project directory passed via `CLAUDE_SPAWN_CWD`.

Implemented in `config/bin/claude-spawn`, `cmd_start()`.

## Impact

This is a Cursor/Claude Code extension bug. If a second Claude session starts
in the same project directory while a Bash tool command is running, the command's
output is silently lost. This affects any workflow that spawns `claude -p` from
within an active session — not just `claude-spawn`.
