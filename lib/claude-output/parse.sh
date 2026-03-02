#!/usr/bin/env bash
# claude-output/parse.sh — Parse Claude TUI terminal output into sections
#
# Standalone library. No dependencies on sub-claude internals.
# Source this file, then call claude_output_parse.
#
# Usage:
#   source /path/to/claude-output/parse.sh
#   echo "$raw_output" | claude_output_parse [--verbosity LEVEL]
#
# Verbosity levels:
#   response     — Final model response only (default)
#   conversation — All user prompts + model responses
#   full         — Everything except header box and status bar
#   raw          — Passthrough, no parsing

# ---------------------------------------------------------------------------
# Line classifiers
# ---------------------------------------------------------------------------

_co_is_header() {
  case "$1" in
    *▐▛*|*▝▜*|*▘▘*|*"Claude Code"*) return 0 ;;
  esac
  return 1
}

_co_is_status_bar() {
  case "$1" in
    *────────*|*⏵⏵*) return 0 ;;
  esac
  # Status info line: "  ~/path branch  Model  N%"
  # Anchored on ~ (home path) to avoid false positives on content like "  CPU: 83%"
  [[ "$1" =~ ^[[:space:]]+~/.+[0-9]+%$ ]]
}

_co_is_trust_prompt() {
  case "$1" in
    *"Do you trust"*|*"Enter to confirm"*|*"Escape to cancel"*) return 0 ;;
  esac
  return 1
}

_co_is_chrome() {
  _co_is_header "$1" || _co_is_status_bar "$1" || _co_is_trust_prompt "$1"
}

_co_is_user_prompt() {
  [[ "$1" =~ ^[[:space:]]*❯ ]]
}

_co_is_model_marker() {
  [[ "$1" =~ ^[[:space:]]*⏺ ]]
}

_co_is_system_output() {
  [[ "$1" =~ ^[[:space:]]*⎿ ]]
}

# _co_is_hook_notification — detect hook summary lines like "⏺ Ran 1 stop hook"
_co_is_hook_notification() {
  [[ "$1" =~ ^[[:space:]]*⏺[[:space:]]+(Ran[[:space:]]+[0-9]+.*hook|Updated) ]]
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# _co_trim_trailing_blanks — remove trailing blank lines.
# Buffers all input, then outputs without trailing blanks.
# Works in both bash and zsh (avoids array index differences).
_co_trim_trailing_blanks() {
  local pending_blanks=""
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -z "$line" ]; then
      pending_blanks="${pending_blanks}
"
    else
      # Flush any pending blank lines (they're not trailing)
      if [ -n "$pending_blanks" ]; then
        printf '%s' "$pending_blanks"
        pending_blanks=""
      fi
      printf '%s\n' "$line"
    fi
  done
  # Drop pending_blanks — they were trailing
}

_co_trim_leading_blanks() {
  local started=false
  while IFS= read -r line || [ -n "$line" ]; do
    if ! $started && [ -z "$line" ]; then
      continue
    fi
    started=true
    printf '%s\n' "$line"
  done
}

_co_trim_blanks() {
  _co_trim_leading_blanks | _co_trim_trailing_blanks
}

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

claude_output_parse() {
  local verbosity="response"

  while [ $# -gt 0 ]; do
    case "$1" in
      --verbosity|-v)
        [ $# -ge 2 ] || { echo "claude_output_parse: -v requires an argument" >&2; return 1; }
        verbosity="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  case "$verbosity" in
    response|conversation|full|raw) ;;
    *) echo "claude_output_parse: unknown verbosity '$verbosity' (use response|conversation|full|raw)" >&2; return 1 ;;
  esac

  if [ "$verbosity" = "raw" ]; then
    cat
    return 0
  fi

  local input
  input=$(cat)

  case "$verbosity" in
    response)     _co_extract_last_response "$input" ;;
    conversation) _co_filter_conversation "$input" ;;
    full)         _co_filter_full "$input" ;;
  esac
}

# ---------------------------------------------------------------------------
# Verbosity: response — last model response block only
# ---------------------------------------------------------------------------
#
# A "response turn" starts at a user prompt (❯) and includes everything
# until the next user prompt. Within a turn, the model response is the
# content after the last hook block.
#
# We collect all turns, then extract the model response from the last one.

_co_extract_last_response() {
  local input="$1"

  # State: none | prompt | model | hook | system
  local state="none"
  local last_model_block=""
  local all_model_block=""

  while IFS= read -r line || [ -n "$line" ]; do
    _co_is_chrome "$line" && continue

    if _co_is_user_prompt "$line"; then
      # Save accumulated model block from previous turn
      if [ -n "$all_model_block" ]; then
        last_model_block="$all_model_block"
      fi
      all_model_block=""
      state="prompt"

    elif _co_is_hook_notification "$line"; then
      # Hook notification — skip it and everything until next ⏺ or ❯
      state="hook"

    elif _co_is_model_marker "$line"; then
      if [ "$state" = "hook" ]; then
        # First ⏺ after a hook — this is the model's retry/response
        state="model"
        all_model_block="$line"
      elif [ "$state" = "model" ]; then
        # Additional ⏺ within same response (e.g. tool use result line)
        all_model_block="${all_model_block}
${line}"
      else
        # Fresh model response
        state="model"
        all_model_block="${all_model_block:+${all_model_block}
}${line}"
      fi

    elif _co_is_system_output "$line"; then
      # ⎿ lines — tool/hook continuation
      if [ "$state" = "model" ]; then
        # System output within model response (tool calls)
        all_model_block="${all_model_block}
${line}"
      fi
      # In hook state, skip

    elif [ "$state" = "model" ]; then
      # Continuation text
      all_model_block="${all_model_block}
${line}"

    elif [ "$state" = "hook" ]; then
      # Continuation of hook output — skip
      :
    fi
  done <<< "$input"

  # Flush final
  if [ -n "$all_model_block" ]; then
    last_model_block="$all_model_block"
  fi

  if [ -n "$last_model_block" ]; then
    printf '%s\n' "$last_model_block" | _co_trim_blanks
  fi
}

# ---------------------------------------------------------------------------
# Verbosity: conversation — user prompts + model responses (no hooks/system)
# ---------------------------------------------------------------------------

_co_filter_conversation() {
  local input="$1"

  # State: none | prompt | model | hook | system
  local state="none"

  while IFS= read -r line || [ -n "$line" ]; do
    _co_is_chrome "$line" && continue

    if _co_is_user_prompt "$line"; then
      state="prompt"
      printf '%s\n' "$line"

    elif _co_is_hook_notification "$line"; then
      state="hook"

    elif _co_is_model_marker "$line"; then
      if [ "$state" = "hook" ]; then
        # Model retry after hook — this is the real response
        state="model"
        printf '%s\n' "$line"
      else
        state="model"
        printf '%s\n' "$line"
      fi

    elif _co_is_system_output "$line"; then
      if [ "$state" = "model" ]; then
        state="system"
      fi
      # Skip system output in conversation mode

    elif [ "$state" = "model" ]; then
      printf '%s\n' "$line"

    elif [ "$state" = "hook" ]; then
      # Skip hook continuation lines
      :

    elif [ "$state" = "prompt" ]; then
      # Multi-line prompt continuation
      printf '%s\n' "$line"
    fi
  done <<< "$input"
}

# ---------------------------------------------------------------------------
# Verbosity: full — everything except header, status bar, trust prompt
# ---------------------------------------------------------------------------

_co_filter_full() {
  local input="$1"

  printf '%s\n' "$input" | while IFS= read -r line || [ -n "$line" ]; do
    _co_is_chrome "$line" && continue
    printf '%s\n' "$line"
  done | _co_trim_blanks
}
