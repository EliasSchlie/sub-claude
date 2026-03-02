# Manual Testing Pool Commands

Unit and integration tests use mocks — safe to run anywhere.

For **manual** verification of pool commands (`pool stop`, `pool gc`, `pool destroy`, etc.):

1. Create a temp dir **outside any git repo**: `cd $(mktemp -d)`
2. Install/symlink sub-claude there
3. Run pool commands only from that directory

This avoids killing a live pool. Pool identity is derived from the project directory — running `pool stop` from a worktree or the main repo targets the same pool.
