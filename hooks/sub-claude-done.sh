#!/usr/bin/env bash
# Signal "done" to sub-claude via the Stop hook. No-op outside pool sessions.
#
# Writes "stop" into $SUB_CLAUDE_DONE_FILE so wait_for_done can validate
# the signal against raw.log for blocking patterns.
# See docs/architecture.md § Completion Detection.
#
# Note: PreToolUse tools (EnterPlanMode, AskUserQuestion, ExitPlanMode)
# are blocked in pool sessions and do NOT signal done — the model keeps
# running after a block.
[ -n "${SUB_CLAUDE_DONE_FILE:-}" ] && echo stop > "$SUB_CLAUDE_DONE_FILE" || true
