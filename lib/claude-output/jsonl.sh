#!/usr/bin/env bash
# claude-output/jsonl.sh — Extract responses from Claude JSONL session transcripts
#
# Standalone library. No dependencies on claude-pool internals.
# Source this file, then call the public functions.
#
# Public API:
#   claude_jsonl_find <uuid> [project_dir]
#     Locate the JSONL file for a given session UUID.
#     Returns file path on stdout, or returns 1 if not found.
#
#   claude_jsonl_last_response <jsonl_path>
#     Extract the last assistant text response from a JSONL transcript.
#     Returns response text on stdout, or returns 1 if empty/not found.

# ---------------------------------------------------------------------------
# claude_jsonl_find <uuid> [project_dir]
# ---------------------------------------------------------------------------
claude_jsonl_find() {
  local uuid="${1:-}" project_dir="${2:-}"

  [ -n "$uuid" ] || return 1

  local base_dir="$HOME/.claude/projects"
  [ -d "$base_dir" ] || return 1

  # Fast path: compute encoded project dir, stat the file directly.
  if [ -n "$project_dir" ]; then
    local encoded
    encoded=$(printf '%s' "$project_dir" | tr '/' '-')
    local candidate="$base_dir/$encoded/$uuid.jsonl"
    if [ -f "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  fi

  # Slow path: glob across all project dirs.
  local match
  # Use nullglob-safe approach: check if file exists for each match.
  for match in "$base_dir"/*/"$uuid.jsonl"; do
    if [ -f "$match" ]; then
      printf '%s' "$match"
      return 0
    fi
  done

  return 1
}

# ---------------------------------------------------------------------------
# claude_jsonl_last_response <jsonl_path>
# ---------------------------------------------------------------------------
claude_jsonl_last_response() {
  local jsonl_path="${1:-}"

  [ -n "$jsonl_path" ] && [ -f "$jsonl_path" ] || return 1

  # grep pre-filters for speed; jq selects the last assistant message with text.
  # Real JSONL has both stop_reason:"end_turn" and stop_reason:null for text
  # messages, so we filter on content type instead of stop_reason.
  local text
  text=$(grep '"type":"assistant"' "$jsonl_path" \
    | grep '"type":"text"' \
    | tail -1 \
    | jq -r '[.message.content[] | select(.type == "text") | .text] | join("\n")' 2>/dev/null)

  [ -n "$text" ] || return 1
  printf '%s' "$text"
}
