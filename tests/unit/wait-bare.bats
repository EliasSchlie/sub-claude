#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2317,SC2329
# Unit tests for bare `cmd_wait` (no ID) — ensures already-finished children
# are excluded so only newly-finished sessions are returned.  (Issue #40)

load '../helpers/setup'
load '../helpers/mocks'

setup() {
  _common_setup
  # cmd_wait calls ensure_pool_exists which needs pool.json
  echo '{"version":1,"pool_size":1,"queue_seq":0,"slots":[],"pins":{}}' \
    > "$POOL_DIR/pool.json"
}
teardown() { _common_teardown; }

# ---------------------------------------------------------------------------
# Helper: create a job with a given status
# ---------------------------------------------------------------------------
_make_job() {
  local id="$1" status="$2"
  mkdir -p "$POOL_DIR/jobs/$id"
  jq -n --arg s "$status" --arg ps "test-parent" \
    '{status: $s, parent_session: $ps}' \
    > "$POOL_DIR/jobs/$id/meta.json"
}

# ---------------------------------------------------------------------------
# Issue #40: bare wait skips already-finished children
# ---------------------------------------------------------------------------

@test "bare wait skips already-finished child and returns newly-finished one" {
  _make_job "aaa00000" "completed"   # already finished
  _make_job "bbb00000" "processing"  # still running

  # Mock _get_children to return both jobs
  _get_children() { echo "aaa00000 bbb00000"; }

  # child_b transitions to finished after the first sleep
  get_job_status() {
    local id="$1"
    case "$id" in
      aaa00000) echo "finished(idle)" ;;
      bbb00000)
        if [ -f "$TEST_DIR/b_finished" ]; then
          echo "finished(idle)"
        else
          echo "processing"
        fi
        ;;
    esac
  }

  # sleep triggers the transition
  sleep() { touch "$TEST_DIR/b_finished"; }

  # Capture which child cmd_result is called with
  cmd_result() { echo "RESULT:$1"; }

  # Suppress queue_pressure output
  queue_pressure() { return 0; }

  run cmd_wait
  [ "$status" -eq 0 ]
  # Must return bbb00000 (newly finished), NOT aaa00000 (stale)
  [[ "$output" == *"RESULT:bbb00000"* ]]
  [[ "$output" != *"RESULT:aaa00000"* ]]
}

@test "bare wait dies when all children were already finished" {
  _make_job "aaa00000" "completed"
  _make_job "bbb00000" "completed"

  _get_children() { echo "aaa00000 bbb00000"; }
  get_job_status() { echo "finished(idle)"; }
  cmd_result() { echo "RESULT:$1"; }
  queue_pressure() { return 0; }

  run cmd_wait
  [ "$status" -eq 1 ]
  [[ "$output" == *"no active child sessions to wait for"* ]]
}

@test "bare wait returns immediately when child finishes after snapshot" {
  _make_job "aaa00000" "processing"  # the only child, still running

  _get_children() { echo "aaa00000"; }

  # Processing during snapshot, finished by first poll
  get_job_status() {
    if [ -f "$TEST_DIR/a_finished" ]; then
      echo "finished(idle)"
    else
      echo "processing"
    fi
  }

  # Transition happens between snapshot and first loop iteration
  sleep() { touch "$TEST_DIR/a_finished"; }
  cmd_result() { echo "RESULT:$1"; }
  queue_pressure() { return 0; }

  run cmd_wait
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESULT:aaa00000"* ]]
}
