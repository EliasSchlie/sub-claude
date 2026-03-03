#!/usr/bin/env bash
# Mock Claude TUI that uses the alternate screen buffer.
# Simulates the real Claude Code behavior where scrollback is lost
# because the alternate screen doesn't accumulate it.
#
# Key difference from mock-claude.sh: enters alternate screen after
# the trust prompt, so output beyond the visible pane height is lost
# to capture-pane (no scrollback in alternate screen mode).
#
# Environment:
#   SUB_CLAUDE_DONE_FILE  — sentinel file to touch on "completion"
#   MOCK_CLAUDE_DELAY      — seconds to sleep before "completing" (default: 0)
#   MOCK_TUI_LINES         — number of output lines to generate (default: 200)

set -uo pipefail

_gen_uuid() {
  printf '%s-%s-%s-%s-%s' \
    "$(xxd -l 4 -p /dev/urandom)" \
    "$(xxd -l 2 -p /dev/urandom)" \
    "$(xxd -l 2 -p /dev/urandom)" \
    "$(xxd -l 2 -p /dev/urandom)" \
    "$(xxd -l 6 -p /dev/urandom)"
}

SESSION_UUID=$(_gen_uuid)
DELAY="${MOCK_CLAUDE_DELAY:-0}"
TUI_LINES="${MOCK_TUI_LINES:-200}"

# --- Trust prompt (BEFORE alternate screen, so accept_trust_prompt works) ---
echo ""
echo "  Do you trust the files in this folder?"
echo "  /Users/test/project"
echo ""
echo "  Enter to confirm, Escape to cancel"
echo ""

IFS= read -r _ 2>/dev/null || true

# --- Enter alternate screen ---
# This is what real Claude Code (Ink/React TUI) does.
# In alternate screen, tmux does NOT accumulate scrollback.
printf '\033[?1049h'

echo "  Claude Code ready."
echo ""
printf '> '

# --- Main input loop ---
while IFS= read -r line; do
  line=$(printf '%s' "$line" | tr -d '\033\001\002\003\004\005\006\007\010\013\014\016\017\020\021\022\023\024\025\026\027\030\031\032\034\035\036\037')
  line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

  [ -z "$line" ] && { printf '> '; continue; }

  case "$line" in
    /status)
      echo ""
      echo "  Session ID: $SESSION_UUID"
      echo "  Model: claude-opus-4-6"
      echo "  CWD: $(pwd)"
      echo "  Press Escape to close"
      echo ""
      ;;

    /clear)
      SESSION_UUID=$(_gen_uuid)
      # Clear the alternate screen
      printf '\033[H\033[2J'
      echo ""
      echo "  Conversation cleared."
      echo "  (no content)"
      echo ""
      printf '> '
      ;;

    /resume\ *)
      local_uuid="${line#/resume }"
      local_uuid=$(printf '%s' "$local_uuid" | tr -d '[:space:]')
      if [ -n "$local_uuid" ]; then
        SESSION_UUID="$local_uuid"
        printf '\033[H\033[2J'
        echo ""
        echo "  Resumed session $SESSION_UUID"
        echo ""
      else
        echo "  Error: /resume requires a session ID"
      fi
      printf '> '
      ;;

    /compact*)
      echo "  Context compacted."
      printf '> '
      ;;

    *)
      # Simulate processing a prompt with lots of output.
      # In alternate screen, lines that scroll past the visible area
      # are NOT preserved in tmux scrollback.
      if [ -n "${MOCK_CLAUDE_FAIL:-}" ]; then
        echo "  Fatal error — exiting"
        exit "$MOCK_CLAUDE_FAIL"
      fi

      echo ""
      echo "  Processing: $line"

      # Simulate TUI spinner animation (cursor-overwrite frames).
      # Real Claude Code emits these via Ink's spinner component.
      # Each frame overwrites the previous via cursor movement, but in
      # raw.log they accumulate as separate lines after ANSI stripping.
      for _sc in ✢ ✳ ✶ ✻ ✽; do
        printf '\033[1A\r%s(thinking)\r\n' "$_sc"
      done
      printf '\033[1A\rForging…\r\n'
      printf '\033[1A\r· Forging…\r\n'

      if [ "$DELAY" -gt 0 ] 2>/dev/null; then
        sleep "$DELAY"
      fi

      # Generate many lines — this overflows the visible pane area
      i=1
      while [ "$i" -le "$TUI_LINES" ]; do
        echo "  RESPONSE LINE $(printf '%03d' "$i"): completed task — $line"
        i=$((i + 1))
      done

      echo ""
      echo "  [task completed]"
      echo ""

      if [ -n "${SUB_CLAUDE_DONE_FILE:-}" ]; then
        touch "$SUB_CLAUDE_DONE_FILE"
      fi

      printf '> '
      ;;
  esac
done

# Exit alternate screen on EOF
printf '\033[?1049l'
