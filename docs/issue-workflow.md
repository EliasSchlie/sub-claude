# Pool-Driven Issue Workflow

Parallel agents tackle issues. Batch related issues into one agent when they share a subsystem or root cause.

## Per-Agent Steps

Stop if any step fails. Don't PR a broken fix.

0. **Triage** — verify the issue aligns with the project's actual goals. Reject AI-generated noise, misguided feature requests, or changes that misunderstand the project's intent.
1. **Read code** — understand the bug(s)
2. **Temp dir** — each agent creates its own: `agent_dir=$(mktemp -d)` — save the path in the job metadata or a variable for re-use
3. **Reproduce** — in the temp dir via `-C "$agent_dir"` — never in the live repo's pool
4. **Worktree** — `git worktree add .claude/worktrees/fix-issue-N -b fix/issue-N`
5. **Failing tests** — follow patterns in `tests/`, confirm they fail before fix
6. **Fix** — minimal change in the worktree
7. **Full test suite** — `./dev.sh test unit` + integration if relevant, all green
8. **Code review** — spawn a review sub-agent via `sub-claude start`, wait for it
9. **Re-reproduce** — in the same `$agent_dir`, confirm bug is gone
10. **PR** — commit with `Fixes #N`, push, `gh pr create`

## Review Cycle

1. Fresh review agent per PR — review diff, file a **GitHub issue** per problem found, comment on PR
2. Fix agents address review issues on the same branch, close the issues
3. Merge all PRs, clean up worktrees and branches
4. Update docs if fixed behavior was documented differently, file issues for new bugs encountered
