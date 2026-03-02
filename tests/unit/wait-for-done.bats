#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031
# Unit tests for wait_for_done (tmux.sh) — completion detection paths.
#
# These tests use the REAL wait_for_done (not the mock) to verify:
#   1. Done file detection (primary path)
#   2. meta.json status fallback (secondary path)
#   3. Idle fallback with warning (tertiary path)
#   4. No false positives from stale done files

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
LIB_DIR="$REPO_ROOT/lib/sub-claude"

setup() {
  export TEST_DIR
  TEST_DIR="$(mktemp -d)"
  export POOL_DIR="$TEST_DIR/pool"
  export TMUX_SOCKET="test-sub-claude-$$"
  mkdir -p "$POOL_DIR/slots/0" "$POOL_DIR/jobs" "$POOL_DIR/queue"

  # Source core + tmux libs (we need the real wait_for_done)
  # shellcheck source=../../lib/sub-claude/core.sh
  source "$LIB_DIR/core.sh"
  # shellcheck source=../../lib/sub-claude/tmux.sh
  source "$LIB_DIR/tmux.sh"

  # Override IDLE_FALLBACK to make tests fast
  IDLE_FALLBACK=2

  # Create a raw.log with some content (needed for idle heuristic)
  echo "some output" > "$POOL_DIR/slots/0/raw.log"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# ---------------------------------------------------------------------------
# Primary path: done file
# ---------------------------------------------------------------------------

@test "wait_for_done returns 0 immediately when done file exists" {
  touch "$POOL_DIR/slots/0/done"
  run wait_for_done "$POOL_DIR/slots/0/done" "$POOL_DIR/slots/0/raw.log" 5
  [ "$status" -eq 0 ]
  # Should NOT emit fallback warning
  [[ "$output" != *"idle fallback"* ]]
}

@test "wait_for_done returns 0 when done file appears mid-poll" {
  # Create done file after 1 second
  ( sleep 1; touch "$POOL_DIR/slots/0/done" ) &
  local bg_pid=$!
  run wait_for_done "$POOL_DIR/slots/0/done" "$POOL_DIR/slots/0/raw.log" 10
  wait "$bg_pid" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [[ "$output" != *"idle fallback"* ]]
}

# ---------------------------------------------------------------------------
# Secondary path: meta.json status check
# ---------------------------------------------------------------------------

@test "wait_for_done returns 0 via meta.json when status is completed" {
  local job_id="aabbccdd"
  mkdir -p "$POOL_DIR/jobs/$job_id"
  echo '{"status": "completed"}' > "$POOL_DIR/jobs/$job_id/meta.json"

  # No done file — should detect via meta.json
  run wait_for_done "$POOL_DIR/slots/0/done" "$POOL_DIR/slots/0/raw.log" 5 "$job_id"
  [ "$status" -eq 0 ]
  # Should NOT emit fallback warning (meta.json caught it)
  [[ "$output" != *"idle fallback"* ]]
}

@test "wait_for_done does not return early when meta.json status is processing" {
  local job_id="aabbccdd"
  mkdir -p "$POOL_DIR/jobs/$job_id"
  echo '{"status": "processing"}' > "$POOL_DIR/jobs/$job_id/meta.json"

  # No done file, status not completed, log grows then stops — idle fallback
  ( sleep 0.5; echo "model output" >> "$POOL_DIR/slots/0/raw.log" ) &
  local bg_pid=$!
  run wait_for_done "$POOL_DIR/slots/0/done" "$POOL_DIR/slots/0/raw.log" 10 "$job_id"
  wait "$bg_pid" 2>/dev/null || true
  [ "$status" -eq 0 ]
  # Should hit idle fallback
  [[ "$output" == *"idle fallback"* ]]
}

@test "wait_for_done without job_id skips meta.json check" {
  # No done file, no job_id, log grows then stops — idle fallback fires
  ( sleep 0.5; echo "model output" >> "$POOL_DIR/slots/0/raw.log" ) &
  local bg_pid=$!
  run wait_for_done "$POOL_DIR/slots/0/done" "$POOL_DIR/slots/0/raw.log" 10
  wait "$bg_pid" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [[ "$output" == *"idle fallback"* ]]
}

# ---------------------------------------------------------------------------
# Tertiary path: idle fallback
# ---------------------------------------------------------------------------

@test "wait_for_done emits warning on idle fallback when log grew" {
  # Grow the log briefly so it has new output beyond the initial size,
  # then stop — idle fallback should fire because work was done.
  ( sleep 0.5; echo "model output" >> "$POOL_DIR/slots/0/raw.log" ) &
  local bg_pid=$!
  run wait_for_done "$POOL_DIR/slots/0/done" "$POOL_DIR/slots/0/raw.log" 10
  wait "$bg_pid" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [[ "$output" == *"Stop hook did not fire"* ]]
  [[ "$output" == *"idle fallback"* ]]
}

# ---------------------------------------------------------------------------
# Issue #26: unsubmitted prompt — idle fallback must NOT fire
# ---------------------------------------------------------------------------

@test "wait_for_done returns 1 when log never grew (unsubmitted prompt)" {
  # raw.log has initial content but never grows — simulates prompt pasted
  # but never submitted. Idle fallback must NOT declare this "done".
  run wait_for_done "$POOL_DIR/slots/0/done" "$POOL_DIR/slots/0/raw.log" 5
  [ "$status" -eq 1 ]
  # Should NOT emit fallback "done" warning
  [[ "$output" != *"idle fallback"* ]]
}

@test "wait_for_done with meta.json processing and no log growth returns 1" {
  local job_id="aabbccdd"
  mkdir -p "$POOL_DIR/jobs/$job_id"
  echo '{"status": "processing"}' > "$POOL_DIR/jobs/$job_id/meta.json"

  # No done file, meta says processing, log never grows — must not complete
  run wait_for_done "$POOL_DIR/slots/0/done" "$POOL_DIR/slots/0/raw.log" 5 "$job_id"
  [ "$status" -eq 1 ]
  [[ "$output" != *"idle fallback"* ]]
}

# ---------------------------------------------------------------------------
# Timeout
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Stop hook block detection
# ---------------------------------------------------------------------------

@test "wait_for_done accepts stop-triggered done when no block in raw.log" {
  echo "stop" > "$POOL_DIR/slots/0/done"
  echo "normal output here" > "$POOL_DIR/slots/0/raw.log"
  run wait_for_done "$POOL_DIR/slots/0/done" "$POOL_DIR/slots/0/raw.log" 5
  [ "$status" -eq 0 ]
  [[ "$output" != *"premature"* ]]
}

@test "wait_for_done accepts empty done file immediately (PreToolUse)" {
  touch "$POOL_DIR/slots/0/done"
  echo "Stop hook error: this should not matter" > "$POOL_DIR/slots/0/raw.log"
  run wait_for_done "$POOL_DIR/slots/0/done" "$POOL_DIR/slots/0/raw.log" 5
  [ "$status" -eq 0 ]
  [[ "$output" != *"premature"* ]]
}

@test "wait_for_done discards stop-triggered done when block detected in raw.log" {
  echo "stop" > "$POOL_DIR/slots/0/done"
  printf 'response text\nStop hook error: You did not add improvement suggestions\n' > "$POOL_DIR/slots/0/raw.log"
  # After discard, no new done file → falls through to timeout
  run wait_for_done "$POOL_DIR/slots/0/done" "$POOL_DIR/slots/0/raw.log" 4
  [ "$status" -eq 1 ]  # times out
}

@test "wait_for_done handles block-then-approve cycle" {
  printf 'first response\nStop hook error: missing suggestions\n' > "$POOL_DIR/slots/0/raw.log"
  echo "stop" > "$POOL_DIR/slots/0/done"

  # After discard, simulate retry: new output and a fresh done file
  (
    sleep 3
    printf 'retry response\nImprovement suggestions: None\n' >> "$POOL_DIR/slots/0/raw.log"
    echo "stop" > "$POOL_DIR/slots/0/done"
  ) &
  local bg_pid=$!

  run wait_for_done "$POOL_DIR/slots/0/done" "$POOL_DIR/slots/0/raw.log" 10
  wait "$bg_pid" 2>/dev/null || true
  [ "$status" -eq 0 ]
}

@test "wait_for_done strips ANSI escapes when checking for block" {
  echo "stop" > "$POOL_DIR/slots/0/done"
  # Simulate ANSI-colored "Stop hook error:" in raw.log
  printf 'output\n\x1b[1mStop hook error:\x1b[0m blocked by check-improvements\n' > "$POOL_DIR/slots/0/raw.log"
  run wait_for_done "$POOL_DIR/slots/0/done" "$POOL_DIR/slots/0/raw.log" 4
  [ "$status" -eq 1 ]  # times out (done signal discarded)
}

# ---------------------------------------------------------------------------
# Timeout
# ---------------------------------------------------------------------------

@test "wait_for_done returns 1 on hard timeout when output keeps growing" {
  # Continuously grow the log so idle fallback never triggers
  (
    for _ in $(seq 1 5); do
      echo "more data" >> "$POOL_DIR/slots/0/raw.log"
      sleep 1
    done
  ) &
  local bg_pid=$!
  run wait_for_done "$POOL_DIR/slots/0/done" "$POOL_DIR/slots/0/raw.log" 3
  kill "$bg_pid" 2>/dev/null || true
  wait "$bg_pid" 2>/dev/null || true
  [ "$status" -eq 1 ]
}
