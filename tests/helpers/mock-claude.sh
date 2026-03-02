#!/usr/bin/env bash
# Mock claude binary for integration tests.
# Simulates the Claude TUI inside tmux panes:
#   - Trust prompt ("Enter to confirm")
#   - /status → prints a UUID
#   - /clear → resets session with new UUID
#   - /resume <uuid> → switches to that session UUID
#   - Any other text → "processes" it, touches CLAUDE_POOL_DONE_FILE
#
# Environment:
#   CLAUDE_POOL_DONE_FILE  — sentinel file to touch on "completion"
#   MOCK_CLAUDE_DELAY      — seconds to sleep before "completing" (default: 0)
#   MOCK_CLAUDE_FAIL       — if set, exit with this code after first prompt
#   MOCK_CLAUDE_JSONL_DIR  — if set, write JSONL transcripts to this directory

set -uo pipefail

# Generate initial session UUID (deterministic from slot for reproducibility)
_gen_uuid() {
  # Use /dev/urandom for a real-ish UUID
  printf '%s-%s-%s-%s-%s' \
    "$(xxd -l 4 -p /dev/urandom)" \
    "$(xxd -l 2 -p /dev/urandom)" \
    "$(xxd -l 2 -p /dev/urandom)" \
    "$(xxd -l 2 -p /dev/urandom)" \
    "$(xxd -l 6 -p /dev/urandom)"
}

SESSION_UUID=$(_gen_uuid)
DELAY="${MOCK_CLAUDE_DELAY:-0}"

# --- Trust prompt ---
echo ""
echo "  Do you trust the files in this folder?"
echo "  /Users/test/project"
echo ""
echo "  Enter to confirm, Escape to cancel"
echo ""

# Wait for Enter (read one line)
IFS= read -r _ 2>/dev/null || true

echo "  Claude Code ready."
echo ""
printf '> '

# --- Main input loop ---
while IFS= read -r line; do
  # Strip control characters (Escape = 0x1b, etc.) that tmux send-keys may inject
  line=$(printf '%s' "$line" | tr -d '\033\001\002\003\004\005\006\007\010\013\014\016\017\020\021\022\023\024\025\026\027\030\031\032\034\035\036\037')
  # Trim leading/trailing whitespace
  line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

  # Skip empty lines (e.g. bare Escape followed by Enter)
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
      echo ""
      echo "  Conversation cleared."
      echo "  (no content)"
      echo ""
      printf '> '
      ;;

    /resume\ *)
      local_uuid="${line#/resume }"
      # Strip any extra whitespace
      local_uuid=$(printf '%s' "$local_uuid" | tr -d '[:space:]')
      if [ -n "$local_uuid" ]; then
        SESSION_UUID="$local_uuid"
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
      # Simulate processing a prompt
      if [ -n "${MOCK_CLAUDE_FAIL:-}" ]; then
        echo "  Fatal error — exiting"
        exit "$MOCK_CLAUDE_FAIL"
      fi

      echo ""
      echo "  Processing: $line"

      if [ "$DELAY" -gt 0 ] 2>/dev/null; then
        sleep "$DELAY"
      fi

      _response="Result: completed task — $line"
      echo "  $_response"
      echo ""

      # Write JSONL transcript if configured
      if [ -n "${MOCK_CLAUDE_JSONL_DIR:-}" ]; then
        mkdir -p "$MOCK_CLAUDE_JSONL_DIR"
        _jsonl="$MOCK_CLAUDE_JSONL_DIR/$SESSION_UUID.jsonl"
        jq -nc --arg text "$line" \
          '{type:"human", message:{role:"user", content:[{type:"text", text:$text}]}}' >> "$_jsonl"
        jq -nc --arg text "$_response" \
          '{type:"assistant", message:{role:"assistant", stop_reason:"end_turn", content:[{type:"text", text:$text}]}}' >> "$_jsonl"
      fi

      # Signal completion via done file
      if [ -n "${CLAUDE_POOL_DONE_FILE:-}" ]; then
        touch "$CLAUDE_POOL_DONE_FILE"
      fi

      printf '> '
      ;;
  esac
done
