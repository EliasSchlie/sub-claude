#!/usr/bin/env bash
# Signal "waiting for input" to sub-claude. No-op outside pool sessions.
#
# PreToolUse reference — creates an empty done file (touch).
# The Stop hook in hooks.json writes "stop" instead, enabling
# wait_for_done to validate Stop signals against raw.log for
# blocking patterns. See docs/architecture.md § Completion Detection.
[ -n "${SUB_CLAUDE_DONE_FILE:-}" ] && touch "$SUB_CLAUDE_DONE_FILE"
