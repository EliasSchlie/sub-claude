#!/usr/bin/env bash
# Signal "waiting for input" to sub-claude. No-op outside pool sessions.
[ -n "${SUB_CLAUDE_DONE_FILE:-}" ] && touch "$SUB_CLAUDE_DONE_FILE"
