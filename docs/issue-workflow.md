# Pool-Driven Issue Workflow

One pool agent per issue, parallel execution, review cycle, merge.

## Per-Issue Agent Steps

Stop if any step fails. Don't PR a broken fix.

1. **Read code** — understand the bug
2. **Reproduce** — in a temp dir (`mktemp -d`), not the live repo
3. **Worktree** — `git worktree add .claude/worktrees/fix-issue-N -b fix/issue-N`
4. **Failing tests** — follow patterns in `tests/`, confirm they fail before fix
5. **Fix** — minimal change in the worktree
6. **Full test suite** — `./dev.sh test unit` + integration if relevant, all green
7. **Code review** — spawn a review sub-agent via `sub-claude start`, wait for it
8. **Re-reproduce** — clone the worktree into a fresh temp dir, confirm bug is gone
9. **PR** — commit with `Fixes #N`, push, `gh pr create`

## Review Cycle

1. Fresh review agent per PR — review diff, file a **GitHub issue** per problem found, comment on PR
2. Fix agents address review issues on the same branch, close the issues
3. Merge all PRs, clean up worktrees and branches
4. Update docs if fixed behavior was documented differently, file issues for new bugs encountered

## Workarounds

- **Unsubmitted prompts** (~25%): if 0% context after dispatch, send `sub-claude key <id> Enter`
- **Always `wait <id>`**, not bare `wait` (returns stale results)
- **`capture` empty for busy sessions**: read `~/.sub-claude/pools/*/slots/N/raw.log` directly
