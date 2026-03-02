#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2329
# Unit tests for config/lib/claude-pool/core.sh

load '../helpers/setup'
load '../helpers/mocks'

setup()    { _common_setup;    }
teardown() { _common_teardown; }

# ---------------------------------------------------------------------------
# gen_id
# ---------------------------------------------------------------------------

@test "gen_id produces 8-char hex string" {
  id=$(gen_id)
  [ "${#id}" -eq 8 ]
  [[ "$id" =~ ^[0-9a-f]{8}$ ]]
}

@test "gen_id produces unique values" {
  id1=$(gen_id)
  id2=$(gen_id)
  [ "$id1" != "$id2" ]
}

# ---------------------------------------------------------------------------
# validate_id
# ---------------------------------------------------------------------------

@test "validate_id accepts valid 8-char hex ID" {
  run validate_id "a1b2c3d4"
  [ "$status" -eq 0 ]
}

@test "validate_id accepts all-digit hex ID" {
  run validate_id "12345678"
  [ "$status" -eq 0 ]
}

@test "validate_id accepts all-letter hex ID" {
  run validate_id "abcdefab"
  [ "$status" -eq 0 ]
}

@test "validate_id rejects too-short ID" {
  run validate_id "a1b2"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid job ID"* ]]
}

@test "validate_id rejects non-hex characters" {
  run validate_id "a1b2c3gx"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid job ID"* ]]
}

@test "validate_id rejects 9-char string" {
  run validate_id "a1b2c3d4e"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# project_hash
# ---------------------------------------------------------------------------

@test "project_hash is deterministic and 8 chars" {
  h1=$(project_hash "/tmp/test")
  h2=$(project_hash "/tmp/test")
  [ "$h1" = "$h2" ]
  [ "${#h1}" -eq 8 ]
}

@test "project_hash differs for different paths" {
  h1=$(project_hash "/path/a")
  h2=$(project_hash "/path/b")
  [ "$h1" != "$h2" ]
}

@test "project_hash output is lowercase hex" {
  h=$(project_hash "/some/path")
  [[ "$h" =~ ^[0-9a-f]{8}$ ]]
}

# ---------------------------------------------------------------------------
# resolve_pool_dir
# ---------------------------------------------------------------------------

@test "resolve_pool_dir sets POOL_DIR and TMUX_SOCKET" {
  # Reset globals to confirm they are written
  POOL_DIR=""
  TMUX_SOCKET=""
  resolve_pool_dir
  [ -n "$POOL_DIR" ]
  [ -n "$TMUX_SOCKET" ]
  [[ "$TMUX_SOCKET" == claude-pool-* ]]
}

@test "resolve_pool_dir TMUX_SOCKET contains 8-char hex hash" {
  resolve_pool_dir
  local hash="${TMUX_SOCKET#claude-pool-}"
  [ "${#hash}" -eq 8 ]
  [[ "$hash" =~ ^[0-9a-f]{8}$ ]]
}

# ---------------------------------------------------------------------------
# get_parent_session_id
# ---------------------------------------------------------------------------

@test "get_parent_session_id returns a non-empty string" {
  result=$(get_parent_session_id)
  [ -n "$result" ]
}

@test "get_parent_session_id returns standalone or PID-timestamp format" {
  result=$(get_parent_session_id)
  # Either "standalone" or "<pid>-<lstart>" format
  [[ "$result" = "standalone" ]] || [[ "$result" =~ ^[0-9]+ ]]
}

# ---------------------------------------------------------------------------
# pool_log
# ---------------------------------------------------------------------------

@test "pool_log appends to pool.log" {
  pool_log "test" "hello world"
  [ -f "$POOL_DIR/pool.log" ]
  grep -q "hello world" "$POOL_DIR/pool.log"
}

@test "pool_log includes component tag" {
  pool_log "mycomponent" "some message"
  grep -q "\[mycomponent\]" "$POOL_DIR/pool.log"
}

@test "pool_log appends (does not overwrite)" {
  pool_log "test" "first line"
  pool_log "test" "second line"
  grep -q "first line"  "$POOL_DIR/pool.log"
  grep -q "second line" "$POOL_DIR/pool.log"
}

# ---------------------------------------------------------------------------
# with_pool_lock
# ---------------------------------------------------------------------------

@test "with_pool_lock executes the given command" {
  result=$(with_pool_lock echo "locked output")
  [ "$result" = "locked output" ]
}

@test "with_pool_lock passes arguments to command" {
  result=$(with_pool_lock printf '%s-%s' "foo" "bar")
  [ "$result" = "foo-bar" ]
}

# ---------------------------------------------------------------------------
# read_pool_json / update_pool_json
# ---------------------------------------------------------------------------

@test "pool.json round-trip preserves content" {
  echo '{"version":1,"test":true}' | update_pool_json
  result=$(read_pool_json)
  [[ "$result" == *'"version"'* ]]
  [[ "$result" == *'"test"'* ]]
}

@test "update_pool_json is atomic (uses tmp then rename)" {
  echo '{"version":1}' | update_pool_json
  [ -f "$POOL_DIR/pool.json" ]
  [ ! -f "$POOL_DIR/pool.json.tmp" ]
}

# ---------------------------------------------------------------------------
# get_job_meta / update_job_meta
# ---------------------------------------------------------------------------

@test "job meta round-trip" {
  local id="a1b2c3d4"
  mkdir -p "$POOL_DIR/jobs/$id"
  echo '{"id":"a1b2c3d4","status":"queued"}' > "$POOL_DIR/jobs/$id/meta.json"

  result=$(get_job_meta "$id")
  [[ "$result" == *"a1b2c3d4"* ]]

  echo '{"id":"a1b2c3d4","status":"completed"}' | update_job_meta "$id"
  result=$(get_job_meta "$id")
  [[ "$result" == *"completed"* ]]
}

@test "update_job_meta is atomic (uses tmp then rename)" {
  local id="a1b2c3d4"
  mkdir -p "$POOL_DIR/jobs/$id"
  echo '{"id":"a1b2c3d4","status":"queued"}' | update_job_meta "$id"
  [ -f "$POOL_DIR/jobs/$id/meta.json" ]
  [ ! -f "$POOL_DIR/jobs/$id/meta.json.tmp" ]
}

# ---------------------------------------------------------------------------
# get_job_status
# ---------------------------------------------------------------------------

@test "get_job_status returns queued" {
  local id="a1b2c3d4"
  mkdir -p "$POOL_DIR/jobs/$id"
  echo '{"status":"queued"}' > "$POOL_DIR/jobs/$id/meta.json"
  echo '{"slots":[]}' | update_pool_json
  status=$(get_job_status "$id")
  [ "$status" = "queued" ]
}

@test "get_job_status returns processing" {
  local id="a1b2c3d4"
  mkdir -p "$POOL_DIR/jobs/$id"
  echo '{"status":"processing"}' > "$POOL_DIR/jobs/$id/meta.json"
  jq -n '{slots:[{index:0,status:"busy",job_id:"a1b2c3d4"}]}' | update_pool_json
  status=$(get_job_status "$id")
  [ "$status" = "processing" ]
}

@test "get_job_status returns finished(idle) for completed non-offloaded job" {
  local id="a1b2c3d4"
  mkdir -p "$POOL_DIR/jobs/$id"
  echo '{"status":"completed","offloaded":false}' > "$POOL_DIR/jobs/$id/meta.json"
  echo '{"slots":[]}' | update_pool_json
  status=$(get_job_status "$id")
  [ "$status" = "finished(idle)" ]
}

@test "get_job_status returns finished(offloaded) for completed offloaded job" {
  local id="a1b2c3d4"
  mkdir -p "$POOL_DIR/jobs/$id"
  echo '{"status":"completed","offloaded":true}' > "$POOL_DIR/jobs/$id/meta.json"
  echo '{"slots":[]}' | update_pool_json
  status=$(get_job_status "$id")
  [ "$status" = "finished(offloaded)" ]
}

@test "get_job_status returns error for error status" {
  local id="a1b2c3d4"
  mkdir -p "$POOL_DIR/jobs/$id"
  echo '{"status":"error"}' > "$POOL_DIR/jobs/$id/meta.json"
  echo '{"slots":[]}' | update_pool_json
  status=$(get_job_status "$id")
  [ "$status" = "error" ]
}

# ---------------------------------------------------------------------------
# get_slot_for_job
# ---------------------------------------------------------------------------

@test "get_slot_for_job finds the correct slot" {
  jq -n '{slots:[{index:2,status:"busy",job_id:"a1b2c3d4"}]}' | update_pool_json
  slot=$(get_slot_for_job "a1b2c3d4")
  [ "$slot" = "2" ]
}

@test "get_slot_for_job returns empty for unknown job" {
  jq -n '{slots:[{index:0,status:"fresh",job_id:null}]}' | update_pool_json
  slot=$(get_slot_for_job "a1b2c3d4")
  [ -z "$slot" ]
}

# ---------------------------------------------------------------------------
# derive_depth
# ---------------------------------------------------------------------------

@test "derive_depth returns a valid non-negative depth" {
  echo '{"version":1,"pool_size":5,"slots":[],"pins":{}}' | update_pool_json
  depth=$(derive_depth)
  # Must be a non-negative integer within the max depth limit
  [[ "$depth" =~ ^[0-9]+$ ]]
  [ "$depth" -lt "$CLAUDE_POOL_MAX_DEPTH" ]
}

@test "derive_depth rejects depth exceeding pool_size - 1" {
  # Pool of size 2: effective max depth = 1, so depth 1 should be rejected.
  # Simulate a parent session at depth 0 that's trying to spawn a child.
  jq -n '{version:1, pool_size:2, slots:[], pins:{}}' | update_pool_json

  # Create a processing job at depth 0 with a known parent_session
  mkdir -p "$POOL_DIR/jobs/parentj1"
  jq -n '{id:"parentj1", status:"processing", depth:0, parent_session:"test-parent-123"}' \
    > "$POOL_DIR/jobs/parentj1/meta.json"

  # Mock get_parent_session_id to return the parent session
  get_parent_session_id() { echo "test-parent-123"; }

  # Child would be depth 1, but pool_size=2 means effective max = 1 → rejected
  run derive_depth
  [ "$status" -eq 1 ]
  [[ "$output" == *"recursion depth"* ]]
}

@test "derive_depth allows depth within pool_size limit" {
  # Pool of size 3: effective max depth = 2, so depth 1 should be allowed.
  jq -n '{version:1, pool_size:3, slots:[], pins:{}}' | update_pool_json

  mkdir -p "$POOL_DIR/jobs/parentj2"
  jq -n '{id:"parentj2", status:"processing", depth:0, parent_session:"test-parent-456"}' \
    > "$POOL_DIR/jobs/parentj2/meta.json"

  get_parent_session_id() { echo "test-parent-456"; }

  depth=$(derive_depth)
  [ "$depth" -eq 1 ]
}

@test "derive_depth uses pool_size limit when smaller than CLAUDE_POOL_MAX_DEPTH" {
  # Pool of size 3 with CLAUDE_POOL_MAX_DEPTH=5:
  # effective max = min(5, 3-1) = 2. Depth 2 should be rejected.
  jq -n '{version:1, pool_size:3, slots:[], pins:{}}' | update_pool_json

  mkdir -p "$POOL_DIR/jobs/parentj3"
  jq -n '{id:"parentj3", status:"processing", depth:1, parent_session:"test-parent-789"}' \
    > "$POOL_DIR/jobs/parentj3/meta.json"

  get_parent_session_id() { echo "test-parent-789"; }

  # Child would be depth 2, effective max = 2 → rejected (>= 2)
  run derive_depth
  [ "$status" -eq 1 ]
  [[ "$output" == *"recursion depth"* ]]
}

@test "derive_depth allows depth-0 with pool_size=1" {
  # pool_size=1: effective_max = max(1, 1-1) = 1, so depth 0 is allowed.
  jq -n '{version:1, pool_size:1, slots:[], pins:{}}' | update_pool_json

  get_parent_session_id() { echo "standalone"; }

  depth=$(derive_depth)
  [ "$depth" -eq 0 ]
}

@test "derive_depth rejects depth-1 with pool_size=1" {
  # pool_size=1: effective_max = 1, so depth 1 (recursion) should be rejected.
  jq -n '{version:1, pool_size:1, slots:[], pins:{}}' | update_pool_json

  mkdir -p "$POOL_DIR/jobs/parentj5"
  jq -n '{id:"parentj5", status:"processing", depth:0, parent_session:"test-parent-bbb"}' \
    > "$POOL_DIR/jobs/parentj5/meta.json"

  get_parent_session_id() { echo "test-parent-bbb"; }

  run derive_depth
  [ "$status" -eq 1 ]
  [[ "$output" == *"recursion depth"* ]]
}

@test "derive_depth error message mentions pool size when pool is the limiting factor" {
  jq -n '{version:1, pool_size:2, slots:[], pins:{}}' | update_pool_json

  mkdir -p "$POOL_DIR/jobs/parentj4"
  jq -n '{id:"parentj4", status:"processing", depth:0, parent_session:"test-parent-aaa"}' \
    > "$POOL_DIR/jobs/parentj4/meta.json"

  get_parent_session_id() { echo "test-parent-aaa"; }

  run derive_depth
  [ "$status" -eq 1 ]
  [[ "$output" == *"pool size"* ]]
}

# ---------------------------------------------------------------------------
# ensure_pool_exists
# ---------------------------------------------------------------------------

@test "ensure_pool_exists succeeds when pool.json exists" {
  echo '{"version":1}' | update_pool_json
  run ensure_pool_exists
  [ "$status" -eq 0 ]
}

@test "ensure_pool_exists dies without pool.json" {
  rm -f "$POOL_DIR/pool.json"
  run ensure_pool_exists
  [ "$status" -eq 1 ]
  [[ "$output" == *"no pool found"* ]]
}

# ---------------------------------------------------------------------------
# is_pool_running
# ---------------------------------------------------------------------------

@test "is_pool_running returns 1 without watcher.pid file" {
  run is_pool_running
  [ "$status" -eq 1 ]
}

@test "is_pool_running returns 1 when watcher.pid is empty" {
  touch "$POOL_DIR/watcher.pid"
  run is_pool_running
  [ "$status" -eq 1 ]
}

@test "is_pool_running returns 1 when watcher pid is dead" {
  # Use a PID that is almost certainly not running
  echo "999999" > "$POOL_DIR/watcher.pid"
  run is_pool_running
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Locked mutation helpers
# ---------------------------------------------------------------------------

@test "_locked_mark_slot_busy updates slot status and job_id" {
  jq -n '{slots:[{index:0,status:"fresh",job_id:null,last_used_at:null}]}' | update_pool_json
  with_pool_lock _locked_mark_slot_busy 0 "a1b2c3d4"
  slot_status=$(read_pool_json | jq -r '.slots[0].status')
  slot_jid=$(read_pool_json | jq -r '.slots[0].job_id')
  [ "$slot_status" = "busy" ]
  [ "$slot_jid" = "a1b2c3d4" ]
}

@test "_locked_update_slot_fresh resets slot to fresh with new uuid" {
  jq -n '{slots:[{index:0,status:"idle",job_id:"a1b2c3d4",last_used_at:"2026-01-01"}]}' | update_pool_json
  with_pool_lock _locked_update_slot_fresh 0 "new-uuid-value"
  slot_status=$(read_pool_json | jq -r '.slots[0].status')
  slot_jid=$(read_pool_json | jq -r '.slots[0].job_id')
  slot_uuid=$(read_pool_json | jq -r '.slots[0].claude_session_id')
  [ "$slot_status" = "fresh" ]
  [ "$slot_jid" = "null" ]
  [ "$slot_uuid" = "new-uuid-value" ]
}

@test "_locked_mark_job_queued sets status to queued" {
  local id="a1b2c3d4"
  mkdir -p "$POOL_DIR/jobs/$id"
  echo '{"id":"a1b2c3d4","status":"processing"}' > "$POOL_DIR/jobs/$id/meta.json"
  with_pool_lock _locked_mark_job_queued "$id"
  result=$(jq -r '.status' "$POOL_DIR/jobs/$id/meta.json")
  [ "$result" = "queued" ]
}

@test "_locked_mark_job_processing sets status and slot" {
  local id="a1b2c3d4"
  mkdir -p "$POOL_DIR/jobs/$id"
  echo '{"id":"a1b2c3d4","status":"queued","slot":null}' > "$POOL_DIR/jobs/$id/meta.json"
  with_pool_lock _locked_mark_job_processing "$id" 2
  result_status=$(jq -r '.status' "$POOL_DIR/jobs/$id/meta.json")
  result_slot=$(jq -r '.slot' "$POOL_DIR/jobs/$id/meta.json")
  [ "$result_status" = "processing" ]
  [ "$result_slot" = "2" ]
}

@test "_locked_mark_job_offloaded sets offloaded to true" {
  local id="a1b2c3d4"
  mkdir -p "$POOL_DIR/jobs/$id"
  echo '{"id":"a1b2c3d4","status":"completed","offloaded":false}' > "$POOL_DIR/jobs/$id/meta.json"
  with_pool_lock _locked_mark_job_offloaded "$id"
  result=$(jq -r '.offloaded' "$POOL_DIR/jobs/$id/meta.json")
  [ "$result" = "true" ]
}

@test "_locked_increment_queue_seq increments and returns new value" {
  echo '{"version":1,"queue_seq":0}' | update_pool_json
  seq=$(with_pool_lock _locked_increment_queue_seq)
  [ "$seq" = "1" ]
  stored=$(read_pool_json | jq -r '.queue_seq')
  [ "$stored" = "1" ]
}
