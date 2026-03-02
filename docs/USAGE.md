---
name: sub-claude
description: Use when needing to run Claude instances in parallel or in sequence — fire-and-forget tasks, multi-turn conversations, or any headless Claude work. Prefer over claude-spawn for all new work.
---

# sub-claude

A **session-oriented pool** of persistent Claude TUI slots backed by tmux. Solves a fundamental problem: launching a new `claude` process while another Claude session has a Bash tool call in flight silently destroys that call's output. sub-claude pre-starts sessions and reuses them — `start`, `followup`, and `wait` never launch new `claude` processes.

**Key difference from claude-spawn:** pool sessions run interactive TUIs (not `claude -p`). Output is captured terminal content, not JSON. Sessions persist across prompts and support multi-turn conversation via `followup`.

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
id=$(sub-claude start "long refactor task")
sub-claude capture "$id"

# Parallel work
id1=$(sub-claude start "task one")
id2=$(sub-claude start "task two")
sub-claude wait  # waits for any direct child
sub-claude wait  # waits for the next one
```

## CLI Reference

```
# Global options
sub-claude [-C <dir>] [-v response|conversation|full|raw] <command> [args]

# Session commands
sub-claude start "prompt" [--block] [--timeout S]
sub-claude followup <id> "prompt" [--block] [--timeout S]
sub-claude input <id> "text"            # type text + Enter into session
sub-claude key <id> Escape|Enter|Up|... # send special key
sub-claude capture <id>                 # live terminal or stored snapshot
sub-claude result <id>                  # final output (errors if still running)
sub-claude wait [<id>] [--quiet] [--timeout S]  # block until done
sub-claude pin <id> [duration]          # prevent offloading (default: 120s)
sub-claude unpin <id>                   # allow offloading again
sub-claude status <id>                  # show session state
sub-claude list [--tree | --all]        # show sessions
sub-claude stop <id> | --tree | --all   # interrupt busy session(s)
sub-claude cancel <id>                  # remove queued job (not yet running)
sub-claude clean <id> [--force | --force-all]

# Pool management
sub-claude pool init [--size N] [--idle-timeout S] [--ttl S] [--pressure-threshold N]
sub-claude pool stop                    # kill pool + tmux server
sub-claude pool status                  # show slots, sessions, queue
sub-claude pool resize N                # add or remove slots
sub-claude pool list                    # list all pools across projects
sub-claude pool destroy <hash> | --all  # tear down a specific or all pools
sub-claude pool migrate                 # clean up old claude-pool artifacts

# Custom commands (see docs/custom-commands.md)
sub-claude run <command> [args...]      # run a custom command script
sub-claude run --list                   # list available commands

# Debug
sub-claude attach <id>                  # attach to tmux pane (live view)
sub-claude uuid <id>                    # print Claude UUID, slot, status

# Cross-project targeting
sub-claude -C /path/to/other/project pool status
sub-claude -C ~/obsidian start "organize notes"
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SUB_CLAUDE_STATE_DIR` | `~/.sub-claude/pools` | Pool metadata root directory |
| `SUB_CLAUDE_VERBOSITY` | `raw` | Output filter level |

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

`status <id>` output:
```
a1b2c3d4   processing            refactor auth module
a1b2c3d4   finished(idle)        fix tests
a1b2c3d4   finished(offloaded)   update docs
a1b2c3d4   queued                add logging
```

## Multi-Turn Conversations

`followup` resumes a finished session with a new prompt — conversation history is preserved.

```bash
id=$(sub-claude start "remember: the password is banana")
sub-claude wait "$id"
sub-claude followup "$id" "what's the password?" --block
```

Rules:
- Only works on **finished** sessions. Errors if still processing (use `wait` first).
- If the session was offloaded, a slot is allocated and the session is resumed automatically.
- Reuses the existing job ID (same session, same conversation).

## Blocking vs Non-Blocking

**Non-blocking (default):** `start` prints the ID and returns immediately. Use `wait` or `capture` to observe progress.

**`--block`:** waits inline, prints terminal output to stdout. ID goes to stderr. Use when you need the result before continuing.

**`--timeout N`:** (seconds) limits how long `--block` or `wait` will poll before giving up. Default: 0 (no limit). On timeout, exits with an error — the job may still be running. Useful for preventing indefinite hangs in automation.

Under **queue pressure** (queued jobs ≥ threshold), `--block` degrades to non-blocking and prints a warning — don't rely on it silently blocking when the pool is saturated. The pressure threshold defaults to half the pool size, configurable via `pool init --pressure-threshold N`. Use `wait <id> --quiet` to block without pressure warnings.

## Terminal Interaction

For interactive sessions or when you need to poke at a running Claude:

```bash
sub-claude key "$id" Escape            # interrupt, dismiss menu
sub-claude key "$id" Enter             # confirm
sub-claude input "$id" "some message"  # type text + Enter
sub-claude capture "$id"               # see current terminal state
```

`input` on an **idle** (finished) session sends text but warns it won't be tracked as a job — use `followup` instead for new prompts.

`attach` opens the tmux pane for direct observation. Both you and `sub-claude` can type — avoid typing while Claude is actively sending keys or outputs will interleave.

## Session Isolation

Each Claude instance only sees the jobs it started:

- `list` / `wait` / `clean` — default: **direct children only**
- `--tree` — includes all descendants (children of children)
- `--all` — every session across all Claude instances in this directory

> `--tree` and `--all` touch sessions from **other Claude instances**. Use sparingly — most workflows should only manage direct children.

Job IDs are scoped to the caller. The pool identifies callers by walking the process tree to the nearest parent `claude` process (PID + start time). Sessions started from a standalone terminal share a `"standalone"` scope.

## Pin / Unpin

Prevents a slot from being reclaimed (offloaded) while you're in the middle of an interactive sequence — menus, multi-step key flows, anything where losing the slot mid-action would break the interaction.

```bash
sub-claude pin "$id"        # default: 120 seconds
sub-claude pin "$id" 300    # 5 minutes
sub-claude unpin "$id"      # release immediately
```

Always prints a reminder:
```
pinned a1b2c3d4 for 120s
warning: pin is for heavy interactive workflows (menus, shortcuts) — not for basic messaging
```

**Don't pin for basic messaging.** `followup` handles offloaded sessions automatically. Pin only when you're sending a sequence of `key`/`input` commands that must land in the same session without interruption.

## Queue Pressure

When all slots are busy, jobs queue up (FIFO). The pool handles this transparently — jobs run as slots free up.

Watch for this warning on `--block`:
```
warning: high queue pressure (3 queued, threshold 3, pool size 5) — not blocking
hint: expand pool with 'sub-claude pool resize N' or wait explicitly with 'sub-claude wait <id> --quiet'
```

When you see it: the call returned the ID immediately without blocking. Either `wait <id>` explicitly, or resize the pool.

```bash
sub-claude pool resize 8    # grow to 8 slots (runs claude in new panes — see caution below)
sub-claude pool status      # inspect current queue + slot state

# Custom threshold: trigger pressure at 2 queued instead of default
sub-claude pool init --size 5 --pressure-threshold 2
```

## Best Practices

**Prefer fire-and-forget + explicit wait:**
```bash
id1=$(sub-claude start "task one")
id2=$(sub-claude start "task two")
sub-claude wait "$id1"
r1=$(sub-claude result "$id1")
sub-claude wait "$id2"
r2=$(sub-claude result "$id2")
```

**Use `followup` for multi-turn, not `input`:**
```bash
# Good
sub-claude followup "$id" "next question" --block

# Only use input for raw terminal interaction (menus, interactive prompts)
sub-claude input "$id" "raw text"
```

**Clean completed sessions to free slots:**
```bash
sub-claude clean --completed       # remove all finished direct children
sub-claude clean "$id"             # remove specific session + its children
```

**Don't block when the pool might be saturated:** check `pool status` if you're launching many jobs and need reliable blocking.

**Auto-init:** if no pool exists when you call `start`, it initializes one automatically (5 slots). You'll see:
```
no pool found — initializing (5 slots)...
```
The job is queued and starts once init completes. No action needed. However, the default 5 slots is a minimum — prefer explicit `pool init --size N` with a larger size before starting work (see [Pool Management](#pool-management)).

## Environment Variables

Pool sessions receive these automatically (set in the per-slot wrapper script):

| Variable | Purpose |
|----------|---------|
| `SUB_CLAUDE=1` | Signals pool session context |
| `SUB_CLAUDE_SLOT=<N>` | Slot index this session runs in |
| `SUB_CLAUDE_DONE_FILE=<path>` | Path the Stop hook writes to signal completion |
| `CLAUDE_BELL_OFF=1` | Suppresses notification bell in hooks |

Check `SUB_CLAUDE` to detect whether you're running inside a pool session.

## Pool Management

```bash
sub-claude pool init           # start 5-slot pool in current project dir
sub-claude pool init --size 8  # explicit size — always overprovision
sub-claude pool status         # inspect slots, queue, pins
sub-claude pool resize 8       # grow (adds slots)
sub-claude pool resize 3       # shrink (decommissions idle slots gracefully)
sub-claude pool stop           # kill everything
```

> **Always overprovision.** Initialize the pool bigger than what you expect to use. Sub-agents spawned by your pool sessions, other Claude instances in the same directory, and automation hooks all consume slots. A pool that looks big enough at launch can saturate quickly once nested work kicks in.

Pool state lives in `~/.sub-claude/pools/<project-hash>/`. One pool per project directory (git root, or `$PWD` outside git). All Claude instances in the same directory share the pool.

> **Pool init and resize run `claude` to create new slots.** This may cause any currently-running Bash tool calls from other Claude sessions in this directory to lose output. Plan init before work starts or during idle periods.

## Troubleshooting

**`error: session a1b2c3d4 is offloaded — pin it first to load into a slot`**
Use `followup` instead of `input`/`key`/`attach`. `followup` handles resume automatically. Pin only if you need interactive key sequences.

**`error: session a1b2c3d4 is still processing — use 'wait' or 'capture'`**
Session hasn't finished. Run `sub-claude wait "$id"` first, then `followup` or `result`.

**`error: session a1b2c3d4 is queued — not yet running`**
All slots are busy. `wait "$id"` and it will run when a slot frees up. Or `sub-claude pool resize N` for more capacity.

**`warning: Stop hook did not fire — completed via idle fallback (30s)`**
The Stop hook (`check-improvements.sh`) isn't configured in `settings.json`, or it failed before calling `pool_done()`. Completion detection fell back to a 30-second idle timer (only triggers if the session's raw.log actually grew, indicating work was performed). Verify `check-improvements.sh` is in the Stop hook (it handles the done signal internally).

**`error: cannot clean a1b2c3d4 — child e5f6a7b8 is still processing`**
A descendant is still running. Either `stop e5f6a7b8` first, or use `clean "$id" --force-all` to stop everything depth-first.

**`warning: high queue pressure — not blocking`**
`--block` returned early. Use `sub-claude wait "$id"` to block explicitly. Resize pool if this happens frequently.

**Session shows `error` status (slot crashed)**
The Claude process in that slot died. Clean the session and retry:
```bash
sub-claude clean "$id"
id2=$(sub-claude start "retry the task")
```
The pool watcher recovers crashed slots automatically after a threshold is reached.

**`attach` shows nothing / pane is blank**
Session is offloaded — `attach` requires a live slot. Use `capture` to see the stored snapshot, or `pin` to reload it into a slot first.

**Idle session shows text in the input field (e.g., "merge the PR")**
This is Claude Code's **auto-suggest** — it pre-fills the input with a suggested next prompt after finishing a task. It is not injected input and not adversarial. Typing anything (or sending a `followup`) overwrites it. Safe to ignore.
