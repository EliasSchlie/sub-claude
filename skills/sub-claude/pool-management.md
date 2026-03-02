# Pool Management

## Commands

```bash
sub-claude pool init           # start 5-slot pool in current project dir
sub-claude pool init --size 8  # explicit size — always overprovision
sub-claude pool status         # inspect slots, queue, pins
sub-claude pool resize 8       # grow (adds slots)
sub-claude pool resize 3       # shrink (decommissions idle slots gracefully)
sub-claude pool stop           # kill everything
```

Pool state lives in `~/.sub-claude/pools/<project-hash>/`.

**Pool scoping:** pools are keyed to the **git root** (or `$PWD` outside git). Running `sub-claude` from any subdirectory within a repo shares the same pool — `~/repo/`, `~/repo/src/`, and `~/repo/tests/` all resolve to one pool. `-C` follows the same rule: `-C ~/repo/src` still targets `~/repo`'s pool.

> **Pool init and resize run `claude` to create new slots.** This may cause any currently-running Bash tool calls from other Claude sessions in this directory to lose output. Plan init before work starts or during idle periods.

## Cross-Project Targeting

Use `-C <dir>` to manage a pool in a different project directory without `cd`-ing there:

```bash
sub-claude -C ~/obsidian pool init --size 3
sub-claude -C ~/obsidian start "organize notes"
sub-claude -C ~/obsidian pool status
sub-claude -C ~/obsidian pool stop
```

`-C` is a routing flag — it targets the other directory's pool. Jobs execute in that directory (where the pool was initialized). Your current project's pool is unaffected.

## Queue Pressure

When all slots are busy, jobs queue (FIFO). The pool handles this transparently — jobs run as slots free up.

Watch for this warning on `--block`:
```
warning: high queue pressure (3 queued, pool size 5) — not blocking
hint: expand pool with 'sub-claude pool resize N' or wait explicitly with 'sub-claude wait <id> --quiet'
```

When you see it: the call returned the ID immediately without blocking. Either `wait <id>` explicitly, or resize the pool.

## Environment Variables

Pool sessions receive these automatically (set in the per-slot wrapper script):

| Variable | Purpose |
|----------|---------|
| `SUB_CLAUDE=1` | Signals pool session context |
| `SUB_CLAUDE_SLOT=<N>` | Slot index this session runs in |
| `SUB_CLAUDE_DONE_FILE=<path>` | Path the Stop hook writes to signal completion |
| `CLAUDE_BELL_OFF=1` | Suppresses notification bell in hooks |

Override these at the CLI level:

| Variable | Default | Purpose |
|----------|---------|---------|
| `SUB_CLAUDE_STATE_DIR` | `~/.sub-claude/pools` | Pool metadata root (must be absolute path) |
| `SUB_CLAUDE_VERBOSITY` | `raw` | Output filter level |

Check `SUB_CLAUDE` to detect whether you're running inside a pool session.
