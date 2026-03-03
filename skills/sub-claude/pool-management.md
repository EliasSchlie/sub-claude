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

`-C <dir>` targets another directory's pool. Jobs execute in that directory (where the pool was initialized), not your current directory. Your current project's pool is unaffected.

## Queue Pressure

When all slots are busy, jobs queue (FIFO). The pool handles this transparently — jobs run as slots free up.

When queued jobs reach half the pool size, `--block` degrades to non-blocking and prints a warning. Fix: `wait <id> --quiet` to block reliably, or `pool resize N` to expand.

## Environment Variables

Check `SUB_CLAUDE=1` to detect whether you're running inside a pool session. Pool sessions also set `SUB_CLAUDE_SLOT`, `SUB_CLAUDE_DONE_FILE`, and `CLAUDE_BELL_OFF` — see `sub-claude --help` for the full list.
