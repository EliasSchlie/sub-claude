#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2329
# Unit tests for send_prompt (tmux.sh) — paste verification logic.
#
# These tests use the REAL send_prompt with a mock tmux_cmd to verify:
#   1. Short prompts use send-keys -l (no paste-buffer)
#   2. Long prompts use paste-buffer with poll-based verification
#   3. Verification loop exits early when pane content changes

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
LIB_DIR="$REPO_ROOT/lib/sub-claude"

setup() {
  export TEST_DIR
  TEST_DIR="$(mktemp -d)"
  export POOL_DIR="$TEST_DIR/pool"
  export TMUX_SOCKET="test-sub-claude-$$"
  mkdir -p "$POOL_DIR/slots/0" "$POOL_DIR/jobs" "$POOL_DIR/queue"

  # Source core + tmux libs (we need the real send_prompt)
  # shellcheck source=../../lib/sub-claude/core.sh
  source "$LIB_DIR/core.sh"
  # shellcheck source=../../lib/sub-claude/tmux.sh
  source "$LIB_DIR/tmux.sh"

  # Track tmux_cmd calls
  export TMUX_CMD_LOG="$TEST_DIR/tmux_cmds.log"
  : > "$TMUX_CMD_LOG"
  # Track capture-pane invocations so the mock returns different hashes
  export CAPTURE_COUNT="$TEST_DIR/capture_count"
  echo "0" > "$CAPTURE_COUNT"

  # Override tmux_cmd after sourcing libs — record calls and simulate
  # capture-pane returning different content each time (hash changes).
  # shellcheck disable=SC2317
  tmux_cmd() {
    echo "$*" >> "$TMUX_CMD_LOG"
    if [ "$1" = "capture-pane" ]; then
      local n
      n=$(cat "$CAPTURE_COUNT")
      n=$((n + 1))
      echo "$n" > "$CAPTURE_COUNT"
      echo "pane-content-$n"
    fi
  }
}

teardown() {
  rm -rf "$TEST_DIR"
}

# ---------------------------------------------------------------------------
# Short prompts (≤400 chars): send-keys path
# ---------------------------------------------------------------------------

@test "send_prompt: short prompt uses send-keys -l, not paste-buffer" {
  send_prompt 0 "short prompt"

  grep -q "send-keys -t pool:slot-0 -l short prompt" "$TMUX_CMD_LOG"
  grep -q "send-keys -t pool:slot-0 Enter" "$TMUX_CMD_LOG"
  run ! grep -q "paste-buffer" "$TMUX_CMD_LOG"
}

@test "send_prompt: exactly 400 chars uses send-keys path" {
  local text
  text=$(printf 'A%.0s' $(seq 1 400))

  send_prompt 0 "$text"

  run ! grep -q "paste-buffer" "$TMUX_CMD_LOG"
  grep -q "send-keys -t pool:slot-0 -l" "$TMUX_CMD_LOG"
}

# ---------------------------------------------------------------------------
# Long prompts (>400 chars): paste-buffer + verification path
# ---------------------------------------------------------------------------

@test "send_prompt: long prompt uses paste-buffer with verification" {
  local text
  text=$(printf 'B%.0s' $(seq 1 500))

  send_prompt 0 "$text"

  # Must use load-buffer + paste-buffer
  grep -q "load-buffer" "$TMUX_CMD_LOG"
  grep -q "paste-buffer" "$TMUX_CMD_LOG"
  # Must capture pane at least twice (before + one poll)
  local cap_count
  cap_count=$(grep -c "capture-pane" "$TMUX_CMD_LOG")
  [ "$cap_count" -ge 2 ]
  # Must end with Enter
  tail -1 "$TMUX_CMD_LOG" | grep -q "Enter"
}

@test "send_prompt: verification exits early when pane changes" {
  local text
  text=$(printf 'C%.0s' $(seq 1 500))

  local start=$SECONDS
  send_prompt 0 "$text"
  local elapsed=$((SECONDS - start))

  # Mock returns different content each call, so verification should
  # succeed on the first poll (well under the 3s timeout).
  [ "$elapsed" -lt 2 ]
}

@test "send_prompt: 401 chars triggers paste-buffer path" {
  local text
  text=$(printf 'D%.0s' $(seq 1 401))

  send_prompt 0 "$text"

  grep -q "paste-buffer" "$TMUX_CMD_LOG"
}
