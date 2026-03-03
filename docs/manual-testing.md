# Manual Testing Pool Commands

Unit and integration tests use mocks — safe to run anywhere.

For **manual** verification of pool commands (`pool stop`, `pool gc`, `pool destroy`, etc.):

## Creating an isolated test pool

Use `SUB_CLAUDE_STATE_DIR` pointed at a **persistent directory** (not `/tmp`):

```bash
mkdir -p ~/sub-claude-test/state
export SUB_CLAUDE_STATE_DIR=~/sub-claude-test/state

sub-claude pool init --size 2
sub-claude pool status
# ... run your tests ...
sub-claude pool stop

# Clean up when done
rm -rf ~/sub-claude-test
```

> **Why not `/tmp`?** macOS aggressively cleans `/tmp` (`/private/tmp`), so pool state can vanish mid-test. Use a persistent directory instead.

> **Why not `-C <dir>` or `cd <dir>`?** Without `--local`, `resolve_pool_dir` falls back to the root pool — so `-C /some/dir` doesn't actually isolate the pool. And `cd`-ing to a non-git dir also falls back to root.

## Reproducing specific issues

### Unhealthy pool (issue #38)

Simulate a dead watcher:
```bash
export SUB_CLAUDE_STATE_DIR=~/sub-claude-test/state
sub-claude pool init --size 2
# Kill the watcher
kill "$(cat "$SUB_CLAUDE_STATE_DIR/_root/watcher.pid")"
sub-claude pool status   # should show "watcher stopped"
sub-claude start "test"  # should auto-recover the watcher
sub-claude pool status   # should show "watcher running"
```

Simulate both watcher and tmux dead:
```bash
kill "$(cat "$SUB_CLAUDE_STATE_DIR/_root/watcher.pid")"
tmux -L sub-claude-root kill-server
sub-claude start "test"  # should do full reinit
```
