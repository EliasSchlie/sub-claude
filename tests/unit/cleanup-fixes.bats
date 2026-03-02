#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2317,SC2329
# Unit tests for cleanup fixes:
#   1. --timeout flag on wait / start --block / followup --block
#   2. --pressure-threshold on pool init + queue_pressure
#   3. TTL busy-slot guard + last_activity_at tracking

load '../helpers/setup'
load '../helpers/mocks'

setup()    { _common_setup;    }
teardown() { _common_teardown; }

# ===========================================================================
# 1. --timeout validation
# ===========================================================================

@test "cmd_wait rejects non-numeric --timeout" {
  echo '{"version":1,"pool_size":1,"queue_seq":0,"slots":[],"pins":{}}' \
    > "$POOL_DIR/pool.json"

  run cmd_wait --timeout abc
  [ "$status" -eq 1 ]
  [[ "$output" == *"non-negative integer"* ]]
}

@test "cmd_wait rejects negative --timeout" {
  echo '{"version":1,"pool_size":1,"queue_seq":0,"slots":[],"pins":{}}' \
    > "$POOL_DIR/pool.json"

  run cmd_wait --timeout -5
  [ "$status" -eq 1 ]
  [[ "$output" == *"non-negative integer"* ]]
}

@test "cmd_start rejects non-numeric --timeout" {
  echo '{"version":1,"pool_size":1,"queue_seq":0,"slots":[],"pins":{}}' \
    > "$POOL_DIR/pool.json"

  run cmd_start "hello" --timeout xyz
  [ "$status" -eq 1 ]
  [[ "$output" == *"non-negative integer"* ]]
}

@test "cmd_followup rejects non-numeric --timeout" {
  echo '{"version":1,"pool_size":1,"queue_seq":0,"slots":[],"pins":{}}' \
    > "$POOL_DIR/pool.json"

  # Create a finished job to pass the status check
  mkdir -p "$POOL_DIR/jobs/aabbcc00"
  echo '{"status":"completed","offloaded":false}' > "$POOL_DIR/jobs/aabbcc00/meta.json"

  run cmd_followup aabbcc00 "follow" --timeout nope
  [ "$status" -eq 1 ]
  [[ "$output" == *"non-negative integer"* ]]
}

# ===========================================================================
# 1b. --timeout fires when job is stuck
# ===========================================================================

@test "cmd_wait times out when job stays queued" {
  echo '{"version":1,"pool_size":1,"queue_seq":0,"slots":[],"pins":{}}' \
    > "$POOL_DIR/pool.json"

  mkdir -p "$POOL_DIR/jobs/aabb0001"
  echo '{"status":"queued"}' > "$POOL_DIR/jobs/aabb0001/meta.json"

  get_job_status() { echo "queued"; }
  sleep() { :; }

  # File-based sentinel: first date +%s call returns 1000, all subsequent return 1100.
  # (variable counters don't survive $() subshell boundaries)
  date() {
    if [ "$1" = "+%s" ]; then
      if [ -f "$TEST_DIR/date_started" ]; then
        echo 1100
      else
        touch "$TEST_DIR/date_started"
        echo 1000
      fi
    else
      command date "$@"
    fi
  }

  run cmd_wait aabb0001 --timeout 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"timed out"* ]]
}

@test "cmd_wait with --timeout 0 does not time out (default behavior)" {
  echo '{"version":1,"pool_size":1,"queue_seq":0,"slots":[],"pins":{}}' \
    > "$POOL_DIR/pool.json"

  mkdir -p "$POOL_DIR/jobs/aabb0002"
  echo '{"status":"completed","offloaded":false}' > "$POOL_DIR/jobs/aabb0002/meta.json"

  # Job is already finished — should return immediately regardless of timeout=0
  jq -n '{
    version: 1, pool_size: 1, queue_seq: 0,
    slots: [{"index":0,"status":"idle","job_id":"aabb0002","claude_session_id":"uuid","last_used_at":null}],
    pins: {}
  }' | update_pool_json

  run cmd_wait aabb0002 --timeout 0
  [ "$status" -eq 0 ]
}

@test "bare cmd_wait times out when children stay processing" {
  echo '{"version":1,"pool_size":1,"queue_seq":0,"slots":[],"pins":{}}' \
    > "$POOL_DIR/pool.json"

  mkdir -p "$POOL_DIR/jobs/aabb0003"
  echo '{"status":"processing","parent_session":"test-parent"}' > "$POOL_DIR/jobs/aabb0003/meta.json"

  _get_children() { echo "aabb0003"; }
  get_job_status() { echo "processing"; }
  sleep() { :; }

  date() {
    if [ "$1" = "+%s" ]; then
      if [ -f "$TEST_DIR/date_started" ]; then
        echo 1100
      else
        touch "$TEST_DIR/date_started"
        echo 1000
      fi
    else
      command date "$@"
    fi
  }

  run cmd_wait --timeout 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"timed out"* ]]
}

# ===========================================================================
# 2. --pressure-threshold
# ===========================================================================

@test "pool_init stores pressure_threshold in pool.json" {
  pool_init --size 1 --pressure-threshold 2
  local val
  val=$(jq -r '.pressure_threshold' "$POOL_DIR/pool.json")
  [ "$val" = "2" ]
}

@test "pool_init defaults pressure_threshold to 0 (auto)" {
  pool_init --size 1
  local val
  val=$(jq -r '.pressure_threshold' "$POOL_DIR/pool.json")
  [ "$val" = "0" ]
}

@test "pool_init rejects non-numeric pressure-threshold" {
  run pool_init --size 1 --pressure-threshold abc
  [ "$status" -eq 1 ]
  [[ "$output" == *"non-negative integer"* ]]
}

@test "pool_init accepts zero pressure-threshold (auto mode)" {
  pool_init --size 1 --pressure-threshold 0
  local val
  val=$(jq -r '.pressure_threshold' "$POOL_DIR/pool.json")
  [ "$val" = "0" ]
}

@test "queue_pressure honors configured threshold" {
  # Pool with size=5 and pressure_threshold=2 (normally auto would be 3)
  echo '{"version":1,"pool_size":5,"pressure_threshold":2,"queue_seq":0,"slots":[],"pins":{}}' \
    | update_pool_json

  # Enqueue 2 jobs — below auto threshold (3), but at configured threshold (2)
  mkdir -p "$POOL_DIR/jobs/aabbcc01" "$POOL_DIR/jobs/aabbcc02"
  echo '{"id":"aabbcc01","status":"p"}' > "$POOL_DIR/jobs/aabbcc01/meta.json"
  echo '{"id":"aabbcc02","status":"p"}' > "$POOL_DIR/jobs/aabbcc02/meta.json"
  enqueue "aabbcc01" "new" "a"
  enqueue "aabbcc02" "new" "b"

  run queue_pressure
  [ "$status" -eq 0 ]
  [[ "$output" == *"high queue pressure"* ]]
}

@test "queue_pressure uses auto formula when threshold=0" {
  # Pool with size=5 and pressure_threshold=0 (auto → threshold=3)
  echo '{"version":1,"pool_size":5,"pressure_threshold":0,"queue_seq":0,"slots":[],"pins":{}}' \
    | update_pool_json

  # Enqueue 2 jobs — below auto threshold of 3
  mkdir -p "$POOL_DIR/jobs/aabbcc01" "$POOL_DIR/jobs/aabbcc02"
  echo '{"id":"aabbcc01","status":"p"}' > "$POOL_DIR/jobs/aabbcc01/meta.json"
  echo '{"id":"aabbcc02","status":"p"}' > "$POOL_DIR/jobs/aabbcc02/meta.json"
  enqueue "aabbcc01" "new" "a"
  enqueue "aabbcc02" "new" "b"

  run queue_pressure
  [ "$status" -eq 1 ]  # no pressure — 2 < 3
}

@test "queue_pressure falls back to auto when threshold missing from pool.json" {
  # Old-style pool.json without pressure_threshold field
  echo '{"version":1,"pool_size":5,"queue_seq":0,"slots":[],"pins":{}}' \
    | update_pool_json

  # Enqueue 2 — below auto threshold of 3
  mkdir -p "$POOL_DIR/jobs/aabbcc01" "$POOL_DIR/jobs/aabbcc02"
  echo '{"id":"aabbcc01","status":"p"}' > "$POOL_DIR/jobs/aabbcc01/meta.json"
  echo '{"id":"aabbcc02","status":"p"}' > "$POOL_DIR/jobs/aabbcc02/meta.json"
  enqueue "aabbcc01" "new" "a"
  enqueue "aabbcc02" "new" "b"

  run queue_pressure
  [ "$status" -eq 1 ]  # no pressure — 2 < 3 (auto formula)
}

@test "queue_pressure shows threshold in warning message" {
  echo '{"version":1,"pool_size":5,"pressure_threshold":1,"queue_seq":0,"slots":[],"pins":{}}' \
    | update_pool_json

  mkdir -p "$POOL_DIR/jobs/aabbcc01"
  echo '{"id":"aabbcc01","status":"p"}' > "$POOL_DIR/jobs/aabbcc01/meta.json"
  enqueue "aabbcc01" "new" "a"

  run queue_pressure
  [ "$status" -eq 0 ]
  [[ "$output" == *"threshold 1"* ]]
}

# ===========================================================================
# 3. TTL busy-slot guard
# ===========================================================================

@test "TTL check skips when a slot is busy" {
  # TTL=1 (very short), last_activity_at is old, but a slot is busy
  jq -n '{
    version: 1,
    pool_size: 1,
    ttl: 1,
    last_activity_at: "2020-01-01T00:00:00Z",
    slots: [{index: 0, status: "busy", job_id: "aabb0001", last_used_at: null}],
    pins: {}
  }' | update_pool_json

  # If TTL fires it calls pool_stop which removes pool.json
  run _watcher_check_ttl
  [ "$status" -eq 0 ]
  # Pool must still exist — TTL should not have fired
  [ -f "$POOL_DIR/pool.json" ]
}

@test "TTL check fires when no slots are busy and TTL exceeded" {
  # TTL=1, last_activity_at is old, slot is idle (not busy)
  jq -n '{
    version: 1,
    pool_size: 1,
    ttl: 1,
    last_activity_at: "2020-01-01T00:00:00Z",
    slots: [{index: 0, status: "idle", job_id: null, last_used_at: null}],
    pins: {}
  }' | update_pool_json

  # pool_stop will try to kill tmux etc — mock it to just remove pool.json
  pool_stop() { rm -f "$POOL_DIR/pool.json"; }

  # _watcher_check_ttl calls exit 0 after pool_stop — run in subshell
  run bash -c "
    source '$LIB_DIR/core.sh'
    source '$LIB_DIR/pool.sh'
    POOL_DIR='$POOL_DIR'
    TMUX_SOCKET='$TMUX_SOCKET'
    pool_stop() { rm -f '$POOL_DIR/pool.json'; }
    tmux_cmd() { return 0; }
    _watcher_check_ttl
  "
  # pool.json should be gone — TTL fired
  [ ! -f "$POOL_DIR/pool.json" ]
}

@test "TTL check falls back to last_dispatch_at for pre-upgrade pools" {
  # Old-style pool.json with last_dispatch_at instead of last_activity_at
  jq -n '{
    version: 1,
    pool_size: 1,
    ttl: 1,
    last_dispatch_at: "2020-01-01T00:00:00Z",
    slots: [{index: 0, status: "fresh", job_id: null, last_used_at: null}],
    pins: {}
  }' | update_pool_json

  pool_stop() { rm -f "$POOL_DIR/pool.json"; }

  run bash -c "
    source '$LIB_DIR/core.sh'
    source '$LIB_DIR/pool.sh'
    POOL_DIR='$POOL_DIR'
    TMUX_SOCKET='$TMUX_SOCKET'
    pool_stop() { rm -f '$POOL_DIR/pool.json'; }
    tmux_cmd() { return 0; }
    _watcher_check_ttl
  "
  # Should have fired TTL using the fallback field
  [ ! -f "$POOL_DIR/pool.json" ]
}

@test "TTL check skips when multiple slots exist and one is busy" {
  jq -n '{
    version: 1,
    pool_size: 2,
    ttl: 1,
    last_activity_at: "2020-01-01T00:00:00Z",
    slots: [
      {index: 0, status: "idle", job_id: null, last_used_at: null},
      {index: 1, status: "busy", job_id: "aabb0001", last_used_at: null}
    ],
    pins: {}
  }' | update_pool_json

  run _watcher_check_ttl
  [ "$status" -eq 0 ]
  [ -f "$POOL_DIR/pool.json" ]
}

# ===========================================================================
# 3b. last_activity_at updated on busy→idle in phase1
# ===========================================================================

@test "phase1 updates last_activity_at when job completes (busy→idle)" {
  local old_time="2020-01-01T00:00:00Z"
  jq -n --arg ts "$old_time" '{
    version: 1,
    pool_size: 1,
    idle_timeout: 0,
    ttl: 0,
    last_activity_at: $ts,
    slots: [{index: 0, status: "busy", job_id: "aabb0004", claude_session_id: "uuid", last_used_at: null}],
    pins: {}
  }' | update_pool_json

  # Create job metadata and done sentinel
  mkdir -p "$POOL_DIR/jobs/aabb0004" "$POOL_DIR/slots/0"
  echo '{"status":"processing"}' > "$POOL_DIR/jobs/aabb0004/meta.json"
  touch "$POOL_DIR/slots/0/done"

  with_pool_lock _watcher_phase1 "0:1 "

  # last_activity_at should have been updated from the old value
  local updated
  updated=$(read_pool_json | jq -r '.last_activity_at')
  [ "$updated" != "$old_time" ]
  [ -n "$updated" ]
}

@test "phase1 updates last_activity_at when busy slot crashes" {
  local old_time="2020-01-01T00:00:00Z"
  jq -n --arg ts "$old_time" '{
    version: 1,
    pool_size: 1,
    idle_timeout: 0,
    ttl: 0,
    last_activity_at: $ts,
    slots: [{index: 0, status: "busy", job_id: "aabb0005", claude_session_id: "uuid", last_used_at: null}],
    pins: {}
  }' | update_pool_json

  mkdir -p "$POOL_DIR/jobs/aabb0005" "$POOL_DIR/slots/0"
  echo '{"status":"processing"}' > "$POOL_DIR/jobs/aabb0005/meta.json"
  # No done file — and pane is dead (0:0 in map)

  with_pool_lock _watcher_phase1 "0:0 "

  local updated
  updated=$(read_pool_json | jq -r '.last_activity_at')
  [ "$updated" != "$old_time" ]

  # Slot should be marked error
  local slot_status
  slot_status=$(read_pool_json | jq -r '.slots[0].status')
  [ "$slot_status" = "error" ]
}
