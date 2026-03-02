#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2329
# Unit tests for pin expiry display in pool_status.
# Regression test for issue #29: negative expiry seconds.

load '../helpers/setup'
load '../helpers/mocks'

setup()    { _common_setup;    }
teardown() { _common_teardown; }

# ---------------------------------------------------------------------------
# Helper: build pool.json with a known pin
# ---------------------------------------------------------------------------
_make_pool_with_pin() {
  local pin_id="$1" pin_deadline="$2"
  jq -n \
    --arg pid "$pin_id" \
    --arg deadline "$pin_deadline" \
    '{
      version: 1,
      project_dir: "/tmp/test",
      tmux_socket: "test-socket",
      pool_size: 1,
      queue_seq: 0,
      slots: [{"index":0,"status":"idle","job_id":$pid,"claude_session_id":null,"last_used_at":"2026-01-01T00:00:00Z"}],
      pins: {($pid): $deadline}
    }' > "$POOL_DIR/pool.json"
}

# ---------------------------------------------------------------------------
# pool_status: pin expiry display
# ---------------------------------------------------------------------------

@test "pool_status shows positive expiry for a pin set 120s in the future" {
  # Compute a deadline 120 seconds from now in UTC
  local now_epoch expiry_epoch deadline
  now_epoch=$(date +%s)
  expiry_epoch=$((now_epoch + 120))
  if date -r "$expiry_epoch" -u +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
    deadline=$(date -r "$expiry_epoch" -u +%Y-%m-%dT%H:%M:%SZ)
  else
    deadline=$(date -d "@$expiry_epoch" -u +%Y-%m-%dT%H:%M:%SZ)
  fi

  _make_pool_with_pin "aabbccdd" "$deadline"

  # Mock is_pool_running to avoid watcher PID check
  is_pool_running() { return 1; }

  run pool_status

  # The output should contain "expires in" with a positive number
  echo "OUTPUT: $output"
  [[ "$output" == *"expires in"* ]]

  # Extract the seconds value — must be positive (not negative)
  local seconds
  seconds=$(echo "$output" | grep -oE 'expires in -?[0-9]+s' | grep -oE -- '-?[0-9]+')
  echo "seconds remaining: $seconds"
  [ "$seconds" -gt 0 ]
}

@test "pool_status shows positive expiry regardless of timezone" {
  # Set a non-UTC timezone to actually verify timezone resilience.
  # The real regression is: UTC deadline parsed as local time shifts by
  # the UTC offset (e.g. UTC-5 → deadline appears 18000s earlier).
  export TZ=America/New_York

  local now_epoch expiry_epoch deadline
  now_epoch=$(date +%s)
  expiry_epoch=$((now_epoch + 300))  # 5 minutes
  if date -r "$expiry_epoch" -u +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
    deadline=$(date -r "$expiry_epoch" -u +%Y-%m-%dT%H:%M:%SZ)
  else
    deadline=$(date -d "@$expiry_epoch" -u +%Y-%m-%dT%H:%M:%SZ)
  fi

  _make_pool_with_pin "bbccddee" "$deadline"
  is_pool_running() { return 1; }

  run pool_status

  local seconds
  seconds=$(echo "$output" | grep -oE 'expires in -?[0-9]+s' | grep -oE -- '-?[0-9]+')
  echo "seconds remaining: $seconds"
  # Must be at least 200s (300 - margin for test execution)
  [ "$seconds" -ge 200 ]
}

@test "_pin_job stores correct UTC deadline" {
  # Setup: pool.json with empty pins, a job dir
  jq -n '{
    version: 1,
    pool_size: 1,
    queue_seq: 0,
    slots: [{"index":0,"status":"idle","job_id":"aabbccdd","last_used_at":"2026-01-01T00:00:00Z"}],
    pins: {}
  }' > "$POOL_DIR/pool.json"
  mkdir -p "$POOL_DIR/jobs/aabbccdd"

  # Pin for 120 seconds
  _pin_job "aabbccdd" 120

  # Read the stored deadline
  local stored_deadline
  stored_deadline=$(jq -r '.pins.aabbccdd' "$POOL_DIR/pool.json")
  echo "stored deadline: $stored_deadline"

  # Parse it back as UTC and compare with now + ~120s
  local deadline_epoch now_epoch diff
  if date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$stored_deadline" +%s >/dev/null 2>&1; then
    deadline_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$stored_deadline" +%s)
  else
    deadline_epoch=$(date -d "$stored_deadline" +%s)
  fi
  now_epoch=$(date +%s)
  diff=$((deadline_epoch - now_epoch))
  echo "deadline_epoch=$deadline_epoch now_epoch=$now_epoch diff=$diff"

  # Should be roughly 120s (allow 10s margin)
  [ "$diff" -ge 110 ]
  [ "$diff" -le 130 ]
}
