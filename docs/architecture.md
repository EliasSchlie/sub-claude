# sub-claude — Implementation Plan

## The Problem

**Running the `claude` command — headless or interactive — breaks every other Claude session in the same project directory.** Specifically: any Claude instance that currently has a Bash tool call in flight will get zero output back from that command. The command runs normally, but its stdout/stderr are silently lost. This happens because Claude Code's transcript-directory file watcher reacts to the new session appearing.

This means:
- `claude-spawn` (headless `claude -p`) is unreliable for parallel work
- You can't simply shell out to `claude` from a Bash tool call
- Any solution that starts a new `claude` process during operation is broken by design

**The key insight:** if we pre-start Claude sessions in tmux panes *before* any work begins, we never need to run the `claude` command again. New conversations use `/clear`, session switches use `/resume <uuid>` — all typed into existing TUI sessions, no new processes.

## Goal

Build `sub-claude` from scratch — a **session-oriented pool** backed by persistent tmux slots running interactive Claude TUIs. Callers work with 8-char hex **job IDs** — slot management, offloading, queueing, and resume are fully transparent. Multiple Claudes in the same directory share one pool.

> `claude-spawn` and the old `claude-tty` were legacy tools used as inspiration. `sub-claude` is now the primary tool for parallel Claude work.

**Guiding principle: fail gracefully, but loudly.**

## Architecture

```
            Caller A              Caller B (recursive child)
               │                       │
         start "prompt"        followup $id "prompt"
               │                       │
               ▼                       ▼
       ┌──────────────────────────────────────────┐
       │          sub-claude orchestrator          │
       │                                          │
       │  Queue (FIFO): [job-3, job-4, ...]       │
       │                                          │
       │  Session mapping:                        │
       │    ID a1b2c3d4 → slot-0 (busy)           │
       │    ID e5f6a7b8 → slot-1 (idle)           │
       │    ID c9d0e1f2 → offloaded (snapshot)    │
       │                                          │
       │  Pin table:                              │
       │    ID e5f6a7b8 → pinned until 10:07:00   │
       └─────────────────┬────────────────────────┘
                         │
         ┌───────────────┴───────────────┐
         ▼                               ▼
  Background watcher            Shared tmux server:
  (polls every 2s)              sub-claude-<project-hash>
  • done files → idle           ├── slot-0  (busy, a1b2c3d4)
  • queue dispatch              ├── slot-1  (idle, e5f6a7b8)
  • crash detection             ├── slot-2  (fresh)
  • pin expiry                  ├── slot-3  (fresh)
                                └── slot-4  (fresh)

State: ~/.sub-claude/pools/<project-hash>/
├── pool.json           # sessions, slot mappings, queue, pins
├── pool.lock           # global lock for pool.json mutations
├── pool.log            # watcher + orchestrator activity log
├── watcher.pid         # background watcher PID
├── queue/
│   ├── 001-<id>.json   # queued jobs (FIFO by filename sort order)
│   └── ...             # see Queue Entry Schema below
├── slots/
│   ├── 0/raw.log       # pipe-pane output
│   ├── 0/done          # sentinel (Stop hook)
│   ├── 0/lock          # lockf target
│   └── ...
└── jobs/
    ├── <id>/meta.json   # prompt, parent session, timestamps
    ├── <id>/snapshot.log # terminal snapshot (stored on offload)
    ├── <id>/warning      # degraded-behavior warnings
    └── ...
```

**Key principles:**
- **Callers only use job IDs** — 8-char hex (e.g., `a1b2c3d4`), same as claude-spawn
- **Claude UUIDs are internal** — the real session UUIDs (used for `/resume`) are managed by the orchestrator; callers never need them
- **One shared pool per project directory** — all Claudes in that CWD share it
- **Session isolation** — each caller sees only its own children by default
- **Fail gracefully, but loudly** — warnings on degraded behavior, never silent failures

### Two kinds of ID

| Name | Format | Who uses it | Example |
|------|--------|-------------|---------|
| **Job ID** | 8-char hex | Callers (models) | `a1b2c3d4` |
| **Claude UUID** | Standard UUID | Orchestrator internally (for `/resume`) | `550e8400-e29b-41d4-a716-446655440000` |

Job IDs are what callers see in `start`, `followup`, `list`, etc. Claude UUIDs are extracted via `/status` and stored in metadata for `/resume`. For debugging, `sub-claude uuid <id>` prints full internal state:
```
claude-uuid: 550e8400-e29b-41d4-a716-446655440000 | slot: 2 | status: idle
```

**Dependencies:** `tmux`, `jq`, `bash` ≥ 4.x, `perl` (for locking on macOS)

**Infrastructure:**
- **One tmux server per project** — socket `sub-claude-<hash>`. Project dir = git root (`git rev-parse --show-toplevel`), falls back to `$PWD` outside git. Hash = first 8 chars via:
  ```bash
  project_hash() { printf '%s' "$1" | (md5 -q 2>/dev/null || md5sum | cut -d' ' -f1) | head -c8; }
  ```
- **Per-slot locking** via `lockf` (native macOS) with `flock` fallback (Linux)
- **No sandbox** — sessions start in caller's CWD, CLAUDE.md loads normally
- **`--dangerously-skip-permissions`** — always used for pool sessions (headless slots can't prompt for approval; use `attach` for manual intervention)
- **Never runs `claude` during operation** — all sessions pre-started; new conversations via `/clear`, session switches via `/resume`
- **`claude` binary only runs during `pool init` and `pool resize` (growing)** — these commands launch new Claude processes in tmux panes. Because this runs the `claude` command, it may cause any currently running Bash tool calls from other Claude sessions in this directory to return no output. Plan pool init for before work starts, or during idle periods.


## CLI

```
# Session commands
sub-claude start "prompt" [--block]
sub-claude followup <id> "prompt" [--block]
sub-claude input <id> "message text"          # type text + Enter (raw terminal input)
sub-claude key <id> Escape|Up|Down|Enter|...  # send special keys
sub-claude capture <id>                       # live terminal or stored snapshot
sub-claude result <id>                        # final output (errors if running)
sub-claude wait [<id>] [--quiet]              # block until done
sub-claude pin <id> [duration]                # prevent offloading (default: 120s)
sub-claude unpin <id>                         # allow offloading again
sub-claude status <id>                        # show session state
sub-claude list [--tree | --all]              # show sessions
sub-claude stop <id> | --tree | --all         # interrupt busy session(s) (Escape → idle)
sub-claude cancel <id>                        # remove from queue (not-yet-running only)
sub-claude clean <id> [--force | --force-all] # clean session + children → slots become fresh
sub-claude clean --completed [--force | --force-all]  # clean completed children
sub-claude clean --tree [--force | --force-all]       # clean all descendants
sub-claude clean --all [--force | --force-all]        # clean everything (all callers)

# Debug / observe
sub-claude attach <id>                        # attach to tmux pane (collaborative!)
sub-claude uuid <id>                          # print Claude UUID, slot, status
sub-claude pool init [--size N]               # start pool (default: 5)
sub-claude pool stop                          # kill pool + tmux server
sub-claude pool status                        # show slots, sessions, queue
sub-claude pool resize N                      # add or remove slots dynamically
sub-claude pool list                          # list all pools across projects
sub-claude pool destroy <hash> | --all        # tear down a specific or all pools
sub-claude pool migrate                       # clean up old claude-pool artifacts
```

> ⚠️ **`--tree` and `--all`** affect sessions from ALL Claude instances in this directory.
> Use sparingly — most workflows should only manage direct children.

### Output formats

**`status <id>`** — single-line state:
```
a1b2c3d4   processing     refactor auth module
a1b2c3d4   finished(idle)        refactor auth module
a1b2c3d4   finished(offloaded)   refactor auth module
a1b2c3d4   queued         refactor auth module
```

**`list`** — all direct children, one per line:
```
a1b2c3d4   processing     refactor auth module
e5f6a7b8   finished(idle)        fix tests
c9d0e1f2   queued         update docs
```

**`list --tree`** — descendants indented:
```
a1b2c3d4   processing     refactor auth module
  b1c2d3e4   finished(idle)    help with tests
  f5a6b7c8   finished(offloaded)  check coverage
e5f6a7b8   finished(idle)        fix tests
```

Cleaned sessions don't appear in `list`.

**`pool status`** — full pool overview:
```
Pool: sub-claude-a1b2c3d4 (5 slots, watcher running)

Slots:
  0  fresh
  1  busy    a1b2c3d4  refactor auth module
  2  idle    e5f6a7b8  fix tests
  3  fresh
  4  error

Queue: 2 pending
  001  c9d0e1f2  update docs
  002  d3e4f5a6  add logging

Pins: 1 active
  e5f6a7b8  expires in 45s
```

> 🔗 **`attach`** opens the tmux pane — you see Claude's live output and can type into the same terminal. Claude interacts via `send-keys` (programmatic), you via the attached terminal. Both inputs go to the same pane. **Caveat:** simultaneous typing interleaves and garbles — avoid typing while Claude is actively sending keys. Best used for observation or taking over when Claude is idle/stuck. Errors if session is offloaded (use `pin` to load it first).

### Output contract

- **`start` (no `--block`)**: prints ID to stdout, returns immediately
- **`start --block`**: ID on stderr; waits and prints terminal output to stdout. Under queue pressure (≥ half pool size queued), returns immediately with warning instead of blocking
- **`followup`**: same contract as `start`
- **`capture`**: live terminal content or stored snapshot (with offload note if applicable)
- **`result`**: same as capture, but errors if session is not idle yet
- **`wait <id>`**: blocks until done, prints terminal output; warns under queue pressure unless `--quiet`
- **`wait`** (no ID): waits until any direct child finishes, prints `--- <id> ---` header to stderr + result to stdout. Call repeatedly to drain.

### Command behavior by session state

Each command's behavior depends on the session's current state. Errors include actionable hints.

| Command | queued | processing (busy) | finished (idle) | finished (offloaded) | error (crashed) |
|---------|--------|-------------------|-----------------|---------------------|-----------------|
| `input` | error: not yet running | ✅ sends text | ⚠️ sends text + warns (untracked) | error + pin hint | error: crashed |
| `key` | error: not yet running | ✅ sends key | ✅ sends key (no warn — keys are low-level) | error + pin hint | error: crashed |
| `capture` | error: not yet running | ✅ live terminal | ✅ live terminal | ✅ stored snapshot (+ offload note) | ✅ last snapshot or error |
| `result` | error: not yet running | error: still processing | ✅ terminal output | ✅ stored snapshot (+ offload note) | ✅ last snapshot or error |
| `followup` | error: already queued | error: still busy | ✅ send directly | queue/resume (needs slot) | error: crashed — clean first |
| `attach` | error: not yet running | ✅ live view | ✅ live view | error + pin hint | error: crashed |
| `pin` | error: nothing to pin | ✅ pin slot | ✅ pin slot | auto-load → pin | error: crashed |
| `clean` | remove from queue | (see force flags) | ✅ offload + clear | ✅ remove metadata | ✅ remove metadata |

**Pin on offloaded session:** finds an idle/fresh slot, `/resume`s the session into it, then pins. If no slot available → error with queue hint.

**Error/warning examples:**
```
error: session a1b2c3d4 is offloaded — pin it first to load into a slot
error: session a1b2c3d4 is queued — not yet running
error: session a1b2c3d4 is still processing — use 'wait' or 'capture'
warning: session a1b2c3d4 is idle — input won't be tracked as a job. Use 'followup' for new prompts.
```

```bash
# Fire-and-forget
id=$(sub-claude start "refactor auth module")

# Blocking
result=$(sub-claude start "explain this codebase" --block)
# ID is on stderr, result is on stdout

# Multi-turn
id=$(sub-claude start "remember: the password is banana")
sub-claude wait "$id"
sub-claude followup "$id" "what's the password?" --block

# Peek at running session
id=$(sub-claude start "long refactor task")
sleep 30
sub-claude capture "$id"   # see what it's doing right now

# Raw terminal interaction (even while busy)
sub-claude key "$id" Escape            # interrupt a menu
sub-claude input "$id" "some message"  # type into session

# Recursive: Claude A starts Claude B via same pool
id_b=$(sub-claude start "help me with tests")
sub-claude wait "$id_b"
sub-claude followup "$id_b" "now fix the failures" --block
```

## States

### Slot states (internal)

```
starting → fresh ↔ busy ↔ idle | error
               ↑          │
               └──────────┘ (clean)
```

- **starting** — tmux pane created, Claude launching, trust prompt pending
- **fresh** — `/clear`'d, UUID extracted, no job loaded. Ready for any new prompt. All slots start fresh after pool init.
- **busy** — processing a job's prompt
- **idle** — job finished, session still loaded, available for followup
- **error** — Claude process crashed (see Crash Recovery)

Fresh slots are preferred over idle slots for new prompts — they don't require offloading.

### Job states (caller-visible)

```
queued → processing → finished (idle) → finished (offloaded)
              │                               │
              └→ error (slot crashed)         └→ (can be /resume'd on demand)
```

- **queued** — waiting for a slot
- **processing** — Claude is working on it
- **finished (idle)** — done, session still loaded in a slot
- **finished (offloaded)** — done, session was offloaded from slot, snapshot stored

## State Schema

```json
{
  "version": 1,
  "project_dir": "/path/to/project",
  "tmux_socket": "sub-claude-a1b2c3d4",
  "pool_size": 5,
  "created_at": "2026-03-01T10:00:00Z",
  "slots": [
    {
      "index": 0,
      "status": "idle",
      "job_id": "a1b2c3d4",
      "claude_session_id": "uuid-for-resume",
      "last_used_at": "2026-03-01T10:05:00Z"
    }
  ],
  "pins": {
    "e5f6a7b8": "2026-03-01T10:07:00Z"
  }
}
```

Slot statuses: `starting` → `fresh` ↔ `busy` ↔ `idle` | `error` | `decommissioning`

Job metadata (`jobs/<id>/meta.json`):
```json
{
  "id": "a1b2c3d4",
  "prompt": "refactor auth module",
  "parent_session": "pid-12345-MonMar...",
  "parent_job_id": null,
  "cwd": "/path/to/project",
  "created_at": "2026-03-01T10:00:00Z",
  "status": "completed",
  "slot": 0,
  "claude_session_id": "uuid-for-resume",
  "offloaded": false,
  "depth": 0
}
```

Queue entry (`queue/NNN-<id>.json`):
```json
{
  "job_id": "a1b2c3d4",
  "type": "new",
  "prompt": "refactor auth module",
  "queued_at": "2026-03-01T10:00:00Z"
}
```

| Field | Values | Description |
|-------|--------|-------------|
| `type` | `"new"` | New conversation — needs a fresh slot (`/clear` → `/status`) |
| `type` | `"resume"` | Resume offloaded session — needs `/resume <claude_uuid>` |
| `claude_uuid` | (only for `resume`) | Target Claude UUID to `/resume` into |
| `prompt` | string | Text to send after slot is ready |

Filename prefix `NNN` is a zero-padded counter (001, 002, ...) ensuring FIFO by lexicographic sort. Counter lives in `pool.json` as `"queue_seq"`.

## Offloading

When a slot is needed for another session. Two variants depending on what comes next:

### Offload → New conversation

When a queued job needs a fresh session (no existing Claude UUID to resume):

1. **Check pin** — if session is pinned, skip this slot, pick another
2. **Escape** — always send `Escape` (harmless no-op at normal prompt, exits interactive menus)
3. **Capture snapshot** → store in `jobs/<id>/snapshot.log`
4. Mark old job as `offloaded: true`
5. **`/clear`** — starts a new conversation
6. **`/status`** → extract new Claude UUID (always after `/clear`!)
7. Escape status menu → fresh session is ready for use

### Offload → Resume existing session

When a queued job needs to resume a previously offloaded session:

1. **Check pin** — if session is pinned, skip this slot, pick another
2. **Escape** — always send `Escape`
3. **Capture snapshot** → store in `jobs/<id>/snapshot.log`
4. **`/resume <target-claude-uuid>`** — switches directly to the target session (no `/clear` needed)
5. Mark old job as `offloaded: true`

> `/resume` switches the conversation in-place — no need to `/clear` first. `/clear` is only for starting brand new conversations.

### Offload notes

When accessing an offloaded session (via `capture`, `result`, or `followup`), output includes:
```
[note: session was offloaded — interactive menus were closed automatically]
```

## Routing & Queue

### Routing (before queueing)

When a prompt arrives (`start` or `followup`), the orchestrator tries to handle it immediately — the queue is a last resort.

**`followup <id>`** — session already known:
1. **Session loaded and idle?** → use that slot directly. No offloading, no resume, no queue. This is the common case.
2. **Session loaded but busy?** → error: `"session busy — wait for it to finish first"` (same as `result` on a running session).
3. **Session offloaded?** → need a slot. If an idle slot exists → offload its session, `/resume <target-uuid>`, send prompt. If no idle slot → queue.
4. **Unknown ID** → error.

**`start`** — new session:
1. **Fresh slot available?** → use it directly. No offloading needed — send prompt.
2. **Idle slot available (no fresh)?** → offload its session (Escape → snapshot → `/clear` → `/status` → slot becomes fresh) → send prompt.
3. **All slots busy** → queue.

> The queue only comes into play when ALL slots are busy. In a pool of 5 with 2 busy, there are 3 idle slots available — no queueing needed.

### Queue processing (FIFO)

When a slot becomes idle (Stop hook fires) and the queue is non-empty:
1. Dequeue next job (FIFO)
2. If job targets an offloaded session → Escape → snapshot → `/resume <target-uuid>` → send prompt
3. If job is new → Escape → snapshot → `/clear` → `/status` (extract new UUID) → send prompt

### Queue pressure

When queue length ≥ half pool size:

- **`start --block`** returns ID + warning immediately (does NOT block):
  ```
  warning: high queue pressure (3 queued, pool size 5) — not blocking
  hint: expand pool with 'sub-claude pool resize N' or wait explicitly with 'sub-claude wait <id> --quiet'
  ```
- **`wait <id>`** prints same warning but still blocks
- **`wait <id> --quiet`** suppresses warnings, blocks silently

### Cancellation

`sub-claude cancel <id>` removes a queued (not yet running) job. Errors if already running (use `stop`).

## Completion Detection

Two layers: Stop hook (primary, instant) + idle heuristic (fallback, warns).

### Primary: Done Sentinel Hook

The done sentinel fires **whenever user input is needed** — matching exactly when the notification bell would ring in a normal session. This covers:

- **Stop** — Claude finished a response turn
- **PreToolUse ExitPlanMode** — Claude proposed a plan (waiting for approval)
- **PreToolUse AskUserQuestion** — Claude asked a question (waiting for answer)

1. Pool init exports `SUB_CLAUDE_DONE_FILE=$slot_dir/done` in the per-slot wrapper script (before launching `claude`)
2. Hook writes to the file (see marker protocol below)
3. `wait`/`--block` polls for sentinel
4. Sentinel `rm`'d before each new prompt

#### Hook delivery: Plugin vs. dotfiles

**Plugin (`hooks/hooks.json`)** — self-contained, installed automatically:
- **Stop**: writes `"stop"` into `$SUB_CLAUDE_DONE_FILE` (marker for block detection)
- **PreToolUse ExitPlanMode|AskUserQuestion**: `touch`es `$SUB_CLAUDE_DONE_FILE` (empty file)

**Dotfiles (legacy)** — if the user has blocking Stop hooks (e.g. `check-improvements.sh`), the done signal for Stop events can be inlined into that hook as `pool_done()`, called only on the `approve` codepath. This avoids premature signals entirely but requires manual wiring.

#### Done file marker protocol

The done file content distinguishes Stop from PreToolUse signals:

| Source | Done file content | Validation |
|--------|------------------|------------|
| Stop hook | `"stop\n"` | `wait_for_done` checks raw.log for blocking patterns |
| PreToolUse hook | empty (0 bytes) | Accepted immediately — never premature |

#### Stop hook block detection (`_stop_hook_blocked`)

When the done file contains `"stop"`, `wait_for_done` validates it against `raw.log`:

1. **Immediate check**: scan recent raw.log (last 2000 bytes, or new content since last discard) for `"Stop hook error:"` pattern
2. **Delayed check** (0.5s): re-scan to tolerate TUI flush latency
3. **If block detected**: delete done file, advance `block_check_offset`, continue polling
4. **If no block**: accept — legitimate completion

The `block_check_offset` tracks the raw.log position of the last discarded signal. Subsequent checks only scan new content, preventing re-matching old block messages from previous retry cycles.

```
Stop hook fires → done file contains "stop"
  → wait_for_done detects it
  → reads content: "stop" → validate
  → _stop_hook_blocked checks raw.log
  → "Stop hook error:" found? → discard, keep waiting
  → not found? → accept, return 0
```

> **Graceful degradation**: the grep pattern (`stop hook error:`) was verified against
> Claude Code ~1.0.x (March 2026). If Claude Code changes this rendering, the pattern
> stops matching and all Stop signals are accepted immediately — equivalent to
> pre-plugin behavior (no regression, just no block detection).

### Fallback: Idle Heuristic (30s)

If neither done sentinel nor meta.json status appears, 30s of no output growth triggers fallback. **Always warns:**
```
warning: Stop hook did not fire — completed via idle fallback (30s)
```

See `wait_for_done()` in `lib/sub-claude/tmux.sh` for the full implementation.

Warning surfaces:
- **Blocking callers** — stderr (visible in Bash tool output)
- **Non-blocking callers** — stored in `jobs/<id>/warning`, printed by `capture`/`result`

## Session Isolation

Each caller identified by walking the process tree to find the nearest parent `claude` process:

```bash
get_parent_session_id() {
  local pid=$$
  while [ "$pid" != "1" ] && [ -n "$pid" ]; do
    local cmd
    cmd=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    if [ "$cmd" = "claude" ]; then
      local lstart
      lstart=$(ps -o lstart= -p "$pid" 2>/dev/null | tr -d ' ') || true
      echo "${pid}-${lstart}"
      return
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || break
  done
  echo "standalone"
}
```

- PID + start time = stable identifier even if PIDs are reused
- `list` / `wait` / `clean` default to **direct children only**
- `--tree` includes all descendants (children of children)
- `--all` shows every session across all callers

**Normal terminal users** can also use the CLI directly (not just Claude instances). When no parent Claude process is found, `get_parent_session_id` returns `"standalone"` — all standalone CLI usage shares one session scope.

> ⚠️ **`--tree` and `--all`** affect sessions from other Claude instances in this directory.
> Only use when intentionally managing cross-session work.

## Pin / Unpin

Prevents a session's slot from being offloaded — for heavy interactive workflows (menus, shortcuts, multi-step key sequences) where offloading mid-interaction would lose state.

```bash
sub-claude pin "$id"       # default: 120 seconds
sub-claude pin "$id" 300   # 5 minutes
sub-claude unpin "$id"     # allow offloading again
```

**Always prints warning:**
```
pinned a1b2c3d4 for 120s
warning: pin is for heavy interactive workflows (menus, shortcuts) — not for basic messaging
```

Pinned sessions are skipped during LRU offloading. If all idle slots are pinned, queue waits.

## Stop

Sends Escape to running (busy) sessions to interrupt processing. Sessions become idle — still loaded in their slots, conversations preserved.

```bash
sub-claude stop <id>           # interrupt this session
sub-claude stop --tree         # interrupt all busy descendants
sub-claude stop --all          # interrupt all busy sessions (all callers)
```

> ⚠️ `--tree` and `--all` affect sessions from other Claude instances. Use sparingly.

Errors if session isn't busy (for single-ID mode). This is a soft interrupt, not destruction — use `clean` to actually free sessions.

## Clean

Cleans sessions: offloads them if loaded, runs the clearing flow (→ slot becomes `fresh`), removes from `list`. Always cascades to children depth-first.

### Default behavior

```bash
sub-claude clean <id>                  # clean this session + all its children
sub-claude clean --completed           # clean all completed (idle/offloaded) direct children + their children
```

**By default, `clean` refuses if any target session or its descendants are busy:**
```
error: cannot clean a1b2c3d4 — child e5f6a7b8 is still processing
hint: stop it first with 'sub-claude stop e5f6a7b8', or use --force
```

### Force flags

| Flag | Behavior |
|------|----------|
| (none) | Clean only idle/offloaded sessions. Error if any target or descendant is busy. |
| `--force` | Also stops (Escape) busy target sessions before cleaning. Still errors if any *descendant* is busy. |
| `--force-all` | Stops everything depth-first — descendants first, then targets. Nuclear option. |

```bash
sub-claude clean "$id" --force         # stop this session if busy, clean it
                                       # but error if its children are busy

sub-claude clean "$id" --force-all     # stop + clean everything depth-first
```

### Scope flags

| Flag | Scope |
|------|-------|
| `<id>` | This session + its children (depth-first) |
| `--completed` | All completed direct children + their children |
| `--tree` | All descendants |
| `--all` | Everything from all callers |

> ⚠️ `--tree` and `--all` affect sessions from other Claude instances. Use sparingly.

### What cleaning does

For each session (depth-first, children before parent):
1. If loaded and busy → error (or stop if `--force`/`--force-all`)
2. If loaded and idle → run offloading flow (Escape → snapshot)
3. Run clearing flow on the slot → `/clear` → `/status` → extract UUID → Escape → slot becomes `fresh`
4. If offloaded → just remove metadata (slot already freed)
5. Remove job from `list` visibility

## Crash Recovery

When a Claude process in a slot dies (OOM, bug, network error), the slot becomes unusable.

**Detection** (by background watcher, every 2s):
- Check if tmux pane is alive: `tmux list-panes -t slot-N` fails → slot is dead
- Mark slot status as `error` in pool.json
- Log: `[watcher] slot-N: pane dead, marking error`

**Recovery threshold**: when ≥ 1/4 of pool slots are `error`, restart them all together:
1. Kill all errored panes
2. Create new panes, launch `claude --dangerously-skip-permissions`
3. Accept trust prompt, `/status` → extract UUID → Escape → `fresh`
4. Log: `[watcher] crash recovery: restarted N slots`

> ⚠️ Crash recovery runs `claude` — may disrupt Bash tool output from other sessions in this directory.

**Per-job impact**: if a slot crashes while processing a job, that job's status becomes `error`. The job's last snapshot (if any) is preserved. Callers see:
```
error: session a1b2c3d4 crashed — slot died during processing
```

## Auto-Init

If no pool exists when `start` is called:

1. Print `"no pool found — initializing (5 slots)..."` to stderr
2. Write job to queue dir (`queue/001-<id>.json`)
3. Return the job ID to stdout **immediately**
4. Launch `pool init` as a **detached background process** (survives parent death):
   ```bash
   ( exec </dev/null >/dev/null 2>&1; sub-claude pool init ) &
   disown
   ```
5. **Do NOT launch `claude` in panes until after returning** — launching `claude` while this Bash call is in flight would cause it to return no output. The detach + disown ensures the `start` call returns before `claude` processes start.
6. Once init completes, watcher starts and picks up the queued job from the queue dir.

> ⚠️ Auto-init launches `claude` processes (the only time this happens outside explicit `pool init`/`pool resize`). Any Bash tool calls from other Claude sessions in this directory may lose output during initialization.

## Pool Resize

`sub-claude pool resize N`:

- **Growing (N > current)**: add new tmux panes, launch Claude in them. ⚠️ Runs `claude` — may cause running Bash tool calls in this directory to lose output.
- **Shrinking (N < current)**: mark excess slots for decommission (`decommissioning` status), offload sessions as they become idle — never kill busy slots

## Key Implementation Details

### Claude UUID Extraction

After `/clear` or on init, run `/status` to get the Claude UUID (needed for future `/resume`):
```bash
tmux send-keys -t slot-N "/status" Enter
sleep 3
pane=$(tmux capture-pane -t slot-N -p -S -50)
uuid=$(printf '%s' "$pane" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | tail -1)
# Dismiss status menu AFTER extracting UUID
tmux send-keys -t slot-N Escape
sleep 0.5
```
Always extract UUID after `/clear` — the old UUID is gone. Not needed after `/resume` (UUID is already known).

### Trust Prompt Auto-Accept

```bash
for _ in 1 2 3 4 5 6 7 8; do
  pane=$(tmux capture-pane -t slot-N -p)
  grep -q "Enter to confirm" <<< "$pane" && tmux send-keys Enter && break
  sleep 2
done
```

### Terminal Capture

**Primary: raw.log** — `capture_raw_log()` reads pipe-pane output directly, strips ANSI escapes, and returns clean text. This bypasses tmux's alternate screen buffer (which Claude Code's TUI uses), recovering full scrollback that `capture-pane` cannot access. A byte offset recorded at dispatch time (`raw_offset` in `meta.json`) isolates the current job's output from previous sessions in the same slot.

**Fallback: capture-pane** — used when raw.log is unavailable or for lightweight checks (trust prompt detection, `/status` hash comparison). All `capture-pane` calls use `-S -100000` for effectively unlimited scrollback:
```bash
tmux capture-pane -t "$slot_target" -p -S -100000
```

**Path selection:**
- `cmd_capture` (processing) → `_emit_pane_full()` → `capture_raw_log()` with capture-pane fallback
- `cmd_capture` (idle) → `_emit_pane_full()` → same path
- `take_snapshot` (offload) → `capture_raw_log()` with capture-pane fallback
- UUID extraction → `capture-pane -S -50` (only needs last few lines)

### Prompt Sending

- Short (≤400 chars): `tmux send-keys -l "$text"` + `send-keys Enter`
- Long: `tmux load-buffer tmpfile` + `paste-buffer` + `send-keys Enter`
- `-l` = literal mode (no key name interpretation)

### Escape Before Offload

Always send Escape before offloading — harmless at normal prompt, exits any interactive menu:
```bash
tmux send-keys -t slot-N Escape
sleep 0.5
# capture snapshot, then either:
#   /clear → /status  (new conversation)
#   /resume <uuid>    (switch to existing session)
```

### Locking

All pool.json mutations go through a global lock to prevent corruption from concurrent callers:

```bash
with_pool_lock() {
  exec 9>"$POOL_DIR/pool.lock"
  if command -v flock >/dev/null; then
    flock 9
  else
    # macOS: no flock — use perl as portable alternative
    perl -e 'use Fcntl qw(:flock); open(my $fh, ">&=", 9); flock($fh, LOCK_EX)'
  fi
  "$@"
  exec 9>&-
}
```

### Slot Allocation

```bash
# Prefer fresh slots, then LRU idle (excluding pinned), returns slot index
allocate_slot() {
  local fresh
  fresh=$(jq -r '[.slots[] | select(.status=="fresh")] | .[0].index // empty' pool.json)
  [ -n "$fresh" ] && echo "$fresh" && return

  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -r --arg now "$now" '
    [.slots[] | select(.status=="idle")] |
    [.[] | select(
      (.job_id as $jid | $ARGS.named.pins[$jid] // "1970") < $now
    )] |
    sort_by(.last_used_at) | .[0].index // empty
  ' --jsonargs "$(jq '.pins' pool.json)" pool.json
}
```

### Background Watcher

Long-running bash loop started by `pool init`, PID stored in `watcher.pid`, killed by `pool stop`. Polls every 2 seconds:

```bash
watcher_loop() {
  while true; do
    # Phase 1: quick state updates (lock held briefly)
    with_pool_lock bash -c '
      # Check done files → mark slots idle, update job status
      # Detect crashed slots (tmux pane dead) → mark error
      # Expire pins past their deadline
      # If ≥ 1/4 slots errored → flag for restart
    '

    # Phase 2: queue dispatch (lock only for state reads/writes)
    # For each pending queue item:
    #   1. Lock → read state, claim slot, mark busy, dequeue → unlock
    #   2. (no lock) perform tmux operations (offload, /clear, /status, send prompt)
    #   3. Lock → update final state → unlock
    dispatch_queue

    sleep 2
  done
}
```

> **Lock discipline:** never hold the global lock during tmux operations (which take seconds). Lock only for pool.json reads/writes (milliseconds). This prevents blocking other callers during offload/dispatch.

Responsibilities:
- **Completion**: detects `$slot_dir/done` → marks slot `idle`, updates job to `finished`
- **Queue dispatch**: dequeues FIFO, allocates slot, sends prompt
- **Crash detection**: checks if tmux pane is alive (`tmux has-session`), marks `error` if dead
- **Crash recovery**: if ≥ 1/4 slots are `error`, restarts them all together (runs `claude` — ⚠️ may disrupt Bash output)
- **Pin expiry**: removes expired pins from pin table

### Pool Init — Parallel Startup

Each slot gets a wrapper script that exports env vars before launching Claude:

```bash
# slots/N/run.sh (generated by pool init)
#!/usr/bin/env bash
export SUB_CLAUDE=1
export SUB_CLAUDE_SLOT=N
export SUB_CLAUDE_DONE_FILE="$POOL_DIR/slots/N/done"
export CLAUDE_BELL_OFF=1
cd "$PROJECT_DIR"
claude --dangerously-skip-permissions
```

```bash
for i in 0..N-1; do init_slot $i & ; done; wait
```

Each `init_slot`: write `run.sh` → start tmux pane running it → accept trust prompt → wait ready → `/status` → extract UUID → Escape (dismiss status menu) → slot is `fresh`.

After all slots ready, start the background watcher.

### Logging

All orchestrator activity is appended to `$POOL_DIR/pool.log`:
- Slot state transitions (fresh → busy → idle, errors, restarts)
- Queue events (enqueue, dequeue, pressure warnings)
- Offload/resume operations
- Crash detection and recovery
- Pin/unpin events

Format: `[timestamp] [component] message`
```
[2026-03-01T10:05:02Z] [watcher] slot-0: done file detected, busy → idle
[2026-03-01T10:05:02Z] [watcher] queue: dispatching job c9d0e1f2 to slot-0
[2026-03-01T10:05:03Z] [watcher] slot-2: pane dead, marking error
```

## Environment Variables

Pool sessions receive these automatically:

| Variable | Purpose |
|----------|---------|
| `SUB_CLAUDE=1` | Signals pool session context |
| `SUB_CLAUDE_SLOT=<N>` | Slot index this session runs in |
| `SUB_CLAUDE_DONE_FILE=<path>` | Done sentinel hook writes this file |
| `CLAUDE_BELL_OFF=1` | Suppress notification bell in hooks |

## Recursion Depth Limit

Maximum recursion depth: **`min(SUB_CLAUDE_MAX_DEPTH, pool_size - 1)`** (at least 1). This ensures at least one slot stays free, preventing deadlock from recursive session chains exhausting the pool. Tracked per-job in `meta.json` (`"depth": N`), **not** via env vars (pool slots are persistent — their env can't change per-job).

| pool_size | effective max depth | free slots |
|-----------|-------------------|------------|
| 1         | 0 (no recursion)  | 1          |
| 2         | 1                 | 1          |
| 3         | 2                 | 1          |
| 5         | 4                 | 1          |
| ≥6        | 5 (capped)        | ≥1         |

**Depth derivation at `start` time:**
1. `get_parent_session_id` identifies the caller
2. Look up caller's active job in pool metadata → read its `depth`
3. New job gets `depth + 1`
4. Standalone/external callers → depth 0
5. At depth ≥ effective max → error with context: `"error: maximum recursion depth (N) reached — pool has M slots"`

## File Structure

Built from scratch — not adapting existing `claude-tty` or `claude-spawn`.

```
config/
├── bin/sub-claude                    # thin dispatcher (~60 lines) — sources lib, routes subcommands
├── lib/sub-claude/
│   ├── core.sh                        # helpers, locking, IDs, session isolation, logging, env
│   ├── pool.sh                        # init, stop, status, resize, watcher loop
│   ├── session.sh                     # start, followup, stop, clean, cancel, wait
│   ├── queue.sh                       # FIFO enqueue/dequeue, dispatch, pressure detection
│   ├── offload.sh                     # offload, resume, snapshot, UUID extraction
│   └── tmux.sh                        # send-keys, capture-pane, trust prompt, slot mgmt
├── claude/hooks/sub-claude-done.sh   # Stop hook sentinel
├── claude/skills/sub-claude/SKILL.md # skill documentation

tests/sub-claude/
├── run.sh                             # test runner (runs all bats files)
├── helpers/
│   ├── setup.bash                     # shared fixtures, pool init/teardown
│   └── mocks.bash                     # mock helpers for unit tests (fake tmux, etc.)
├── unit/                              # fast, isolated, mock tmux interactions
│   ├── core.bats                      # ID generation, locking, session isolation, depth limit
│   ├── queue.bats                     # FIFO ordering, pressure detection, cancel
│   ├── state.bats                     # pool.json mutations, slot allocation, job state transitions
│   └── offload.bats                   # offload/resume logic, snapshot storage
├── integration/                       # real Claude sessions, minimal mocking
│   ├── pool-lifecycle.bats            # init, stop, status, auto-init, double-init, resize
│   ├── session.bats                   # start, --block, followup, input, key, capture, result
│   ├── offload-resume.bats            # offload stores snapshot, resume restores, offload notes
│   ├── queue.bats                     # FIFO under load, pressure warnings, --block degradation
│   ├── concurrent.bats                # parallel starts, shared pool, session isolation
│   └── pin.bats                       # pin prevents offload, unpin, auto-expiry
```

**Deploy targets** (`deploy.sh` additions):
- `config/bin/sub-claude` → `~/.local/bin/sub-claude`
- `config/lib/sub-claude/*.sh` → `~/.local/lib/sub-claude/*.sh`

**Lib resolution** in dispatcher:
```bash
SUB_CLAUDE_LIB="${BASH_SOURCE%/*}/../lib/sub-claude"
for f in "$SUB_CLAUDE_LIB"/*.sh; do source "$f"; done
```

## Files to Modify

| File | Action |
|------|--------|
| `config/claude/settings.json` | **Update** — add Stop hook entry |
| `config/claude/skills/claude-spawn/SKILL.md` | **Update** — remove sub-claude section, cross-reference |
| `deploy.sh` | **Update** — add lib/ deploy target |

## Development Methodology

**Test-driven development.** For each implementation phase:

1. **Write failing tests first** — define expected behavior before writing code
2. **Implement until tests pass** — minimal code to satisfy the tests
3. **Refactor** — clean up while tests stay green

### Implementation Order

1. **Stop hook** — `sub-claude-done.sh` + settings.json entry
2. **Core lib** (`core.sh`) — helpers, locking, IDs, session isolation, logging, depth derivation
3. **Tmux lib** (`tmux.sh`) — send-keys, capture-pane, trust prompt, slot management
4. **State lib** (part of `core.sh`) — pool.json mutations, slot allocation
5. **Pool lifecycle** (`pool.sh`) — init, stop, status
6. **Offloading** (`offload.sh`) — Escape → snapshot → `/clear`/`/resume` flows
7. **Queue** (`queue.sh`) — FIFO, dispatch, pressure detection
8. **Session commands** (`session.sh`) — start, followup, wait, stop, clean, cancel
9. **Input / Key / Capture / Result** — terminal interaction commands
10. **Pin / Unpin** — offload prevention
11. **Pool resize** — grow/shrink
12. **Auto-init** — pool creation on first `start`
13. **Background watcher** (`pool.sh`) — completion, queue dispatch, crash recovery
14. **Skill** — SKILL.md documentation

### Autonomous execution

**Do not return to the user unless:**
- You have an **urgent question** that blocks progress (ambiguous requirement, conflicting constraints)
- **Everything is working** — all tests pass, all verification complete

Work silently through failures, debugging, and iteration. The user expects you to figure it out.

### Verification pipeline (after all tests pass)

1. **`shellcheck`** all `.sh` files — clean, no warnings
2. **`bash -n`** all `.sh` files — syntax OK
3. **Unit tests** — `bats tests/sub-claude/unit/`
4. **Integration tests** — `bats tests/sub-claude/integration/` (real Claude sessions, pool size 2)
5. **Code review agent** — spawn a sub-agent to review all written code for quality, security, edge cases
6. **Plan compliance agent** — spawn a sub-agent with the plan file path, ask it to verify every requirement in the plan is implemented and tested
7. **Live verification** — use `sub-claude` yourself:
   - Init a pool, start a session, wait for result
   - Start a second session, verify parallel execution
   - Followup on a completed session
   - Start a Claude instance and ask it to use `sub-claude` to spawn a sub-Claude (recursive test)
   - Verify session isolation (children only see their own jobs)
   - Verify offloading works (fill pool, check snapshots)
8. **`deploy.sh`** — deploys correctly, commands work from `~/.local/bin/`
