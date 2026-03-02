# Manual Testing Pool Commands

Unit and integration tests use mocks — safe to run anywhere.

For **manual** verification of pool commands (`pool stop`, `pool gc`, `pool destroy`, etc.):

**Option A — `-C` flag (recommended):** target a temp dir without leaving your project:
```bash
dir=$(mktemp -d)
sub-claude -C "$dir" pool init --size 2
sub-claude -C "$dir" pool status
sub-claude -C "$dir" pool stop
```

**Option B — isolated state dir:** override `SUB_CLAUDE_STATE_DIR` to keep pool metadata completely separate:
```bash
export SUB_CLAUDE_STATE_DIR=$(mktemp -d)/pools
sub-claude pool init --size 2   # metadata goes to temp dir, not ~/.sub-claude/
sub-claude pool stop
```

**Option C — `cd` to a temp dir:**
```bash
cd $(mktemp -d)
sub-claude pool init --size 2
sub-claude pool stop
```

All three avoid killing a live pool. Pool identity is derived from the project directory (git root, or `$PWD` outside git) — running `pool stop` from anywhere within the repo targets the same pool.
