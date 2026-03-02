#!/usr/bin/env bash
# Protect sub-claude pool sessions from self-destructive actions:
# - EnterWorktree (traps slot in wrong directory)
# - sub-claude pool stop/gc/destroy without -C (kills own pool)
[ "${SUB_CLAUDE:-}" = "1" ] || exit 0

input=$(cat)

# Bash: block sub-claude pool stop/gc/destroy without -C
if printf '%s\n' "$input" | grep -qE 'sub-claude\b.*\bpool\s+(stop|gc|destroy)' && \
   ! printf '%s\n' "$input" | grep -qE 'sub-claude\b.*-C\b'; then
  echo '{"decision":"block","reason":"You are a sub-claude agent. Cannot stop/gc/destroy your own sub-claude pool. Use -C to target a different pool."}'
  exit 0
fi

# If it's a Bash call (has "command" field), nothing more to check
printf '%s\n' "$input" | grep -q '"command"' && exit 0

# Otherwise it's EnterWorktree — block unconditionally
echo '{"decision":"block","reason":"You are a sub-claude agent. EnterWorktree is blocked — worktrees trap the sub-claude slot in a different directory."}'
