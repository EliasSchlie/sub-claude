#!/usr/bin/env bash
# Signal "waiting for input" to claude-pool. No-op outside pool sessions.
[ -n "${CLAUDE_POOL_DONE_FILE:-}" ] && touch "$CLAUDE_POOL_DONE_FILE"
