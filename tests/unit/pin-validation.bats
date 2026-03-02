#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2329
# Unit tests for pin duration validation (issue #5).

load '../helpers/setup'
load '../helpers/mocks'

setup()    { _common_setup;    }
teardown() { _common_teardown; }

# ---------------------------------------------------------------------------
# Helper: create a finished job so cmd_pin can proceed past status check
# ---------------------------------------------------------------------------
_make_finished_job() {
  local job_id="$1"
  mkdir -p "$POOL_DIR/jobs/$job_id"
  printf '{"status":"completed","offloaded":false}\n' > "$POOL_DIR/jobs/$job_id/meta.json"

  # pool.json with job in an idle slot
  jq -n --arg jid "$job_id" '{
    version: 1,
    project_dir: "/tmp/test",
    tmux_socket: "test-socket",
    pool_size: 1,
    queue_seq: 0,
    slots: [{"index":0,"status":"idle","job_id":$jid,"claude_session_id":null,"last_used_at":"2026-01-01T00:00:00Z"}],
    pins: {}
  }' > "$POOL_DIR/pool.json"
}

# ---------------------------------------------------------------------------
# Validation: reject bad durations
# ---------------------------------------------------------------------------

@test "pin rejects negative duration" {
  _make_finished_job "aabbccdd"
  run cmd_pin "aabbccdd" -5
  echo "status=$status output=$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"duration must be a positive integer"* ]]
  [[ "$output" == *"'-5'"* ]]
}

@test "pin rejects non-numeric duration" {
  _make_finished_job "aabbccdd"
  run cmd_pin "aabbccdd" abc
  echo "status=$status output=$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"duration must be a positive integer"* ]]
  [[ "$output" == *"'abc'"* ]]
}

@test "pin rejects zero duration" {
  _make_finished_job "aabbccdd"
  run cmd_pin "aabbccdd" 0
  echo "status=$status output=$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"duration must be a positive integer"* ]]
  [[ "$output" == *"'0'"* ]]
}

@test "pin accepts valid positive integer duration" {
  _make_finished_job "aabbccdd"
  run cmd_pin "aabbccdd" 120
  echo "status=$status output=$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pinned aabbccdd"* ]]
}
