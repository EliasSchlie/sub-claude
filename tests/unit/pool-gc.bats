#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2329
# Unit tests for pool lifecycle management: idle reaping, TTL, and gc.
# Covers GitHub issue #9.

load '../helpers/setup'
load '../helpers/mocks'

setup()    { _common_setup;    }
teardown() { _common_teardown; }

# ---------------------------------------------------------------------------
# pool_init: --idle-timeout and --ttl flags
# ---------------------------------------------------------------------------

@test "pool_init stores idle_timeout in pool.json" {
  pool_init --size 1 --idle-timeout 600
  local val
  val=$(jq -r '.idle_timeout' "$POOL_DIR/pool.json")
  [ "$val" = "600" ]
}

@test "pool_init stores ttl in pool.json" {
  pool_init --size 1 --ttl 3600
  local val
  val=$(jq -r '.ttl' "$POOL_DIR/pool.json")
  [ "$val" = "3600" ]
}

@test "pool_init stores last_dispatch_at in pool.json" {
  pool_init --size 1
  local val
  val=$(jq -r '.last_dispatch_at' "$POOL_DIR/pool.json")
  [ "$val" != "null" ]
  [ -n "$val" ]
}

@test "pool_init defaults idle_timeout to 1800" {
  pool_init --size 1
  local val
  val=$(jq -r '.idle_timeout' "$POOL_DIR/pool.json")
  [ "$val" = "1800" ]
}

@test "pool_init defaults ttl to 7200" {
  pool_init --size 1
  local val
  val=$(jq -r '.ttl' "$POOL_DIR/pool.json")
  [ "$val" = "7200" ]
}

@test "pool_init rejects non-numeric idle-timeout" {
  run pool_init --size 1 --idle-timeout abc
  [ "$status" -eq 1 ]
  [[ "$output" == *"non-negative integer"* ]]
}

@test "pool_init rejects non-numeric ttl" {
  run pool_init --size 1 --ttl xyz
  [ "$status" -eq 1 ]
  [[ "$output" == *"non-negative integer"* ]]
}

@test "pool_init accepts zero idle-timeout (disabled)" {
  pool_init --size 1 --idle-timeout 0
  local val
  val=$(jq -r '.idle_timeout' "$POOL_DIR/pool.json")
  [ "$val" = "0" ]
}

@test "pool_init accepts zero ttl (no auto-shutdown)" {
  pool_init --size 1 --ttl 0
  local val
  val=$(jq -r '.ttl' "$POOL_DIR/pool.json")
  [ "$val" = "0" ]
}

# ---------------------------------------------------------------------------
# Idle slot reaping in _watcher_phase1
# ---------------------------------------------------------------------------

@test "phase1 marks idle slot for reaping when past idle_timeout" {
  # Pool with idle_timeout=1 (1 second) and an idle slot with old last_used_at
  local old_time="2020-01-01T00:00:00Z"
  jq -n --arg ts "$old_time" '{
    version: 1,
    pool_size: 1,
    idle_timeout: 1,
    ttl: 0,
    slots: [{index: 0, status: "idle", job_id: "aabbccdd", last_used_at: $ts}],
    pins: {}
  }' | update_pool_json

  mkdir -p "$POOL_DIR/slots/0"
  mkdir -p "$POOL_DIR/jobs/aabbccdd"
  echo '{"status":"completed"}' > "$POOL_DIR/jobs/aabbccdd/meta.json"

  with_pool_lock _watcher_phase1 "0:1 "

  local slot_status
  slot_status=$(read_pool_json | jq -r '.slots[0].status')
  [ "$slot_status" = "reaping" ]
}

@test "phase1 does NOT reap idle slot when idle_timeout=0 (disabled)" {
  local old_time="2020-01-01T00:00:00Z"
  jq -n --arg ts "$old_time" '{
    version: 1,
    pool_size: 1,
    idle_timeout: 0,
    ttl: 0,
    slots: [{index: 0, status: "idle", job_id: "aabbccdd", last_used_at: $ts}],
    pins: {}
  }' | update_pool_json

  mkdir -p "$POOL_DIR/slots/0"
  mkdir -p "$POOL_DIR/jobs/aabbccdd"
  echo '{"status":"completed"}' > "$POOL_DIR/jobs/aabbccdd/meta.json"

  with_pool_lock _watcher_phase1 "0:1 "

  local slot_status
  slot_status=$(read_pool_json | jq -r '.slots[0].status')
  [ "$slot_status" = "idle" ]
}

@test "phase1 does NOT reap recently used idle slot" {
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -n --arg ts "$now" '{
    version: 1,
    pool_size: 1,
    idle_timeout: 1800,
    ttl: 0,
    slots: [{index: 0, status: "idle", job_id: "aabbccdd", last_used_at: $ts}],
    pins: {}
  }' | update_pool_json

  mkdir -p "$POOL_DIR/slots/0"
  mkdir -p "$POOL_DIR/jobs/aabbccdd"
  echo '{"status":"completed"}' > "$POOL_DIR/jobs/aabbccdd/meta.json"

  with_pool_lock _watcher_phase1 "0:1 "

  local slot_status
  slot_status=$(read_pool_json | jq -r '.slots[0].status')
  [ "$slot_status" = "idle" ]
}

# ---------------------------------------------------------------------------
# _watcher_check_ttl
# ---------------------------------------------------------------------------

@test "TTL check does nothing when ttl=0" {
  jq -n '{
    version: 1,
    pool_size: 1,
    ttl: 0,
    last_dispatch_at: "2020-01-01T00:00:00Z",
    slots: [],
    pins: {}
  }' | update_pool_json

  # Should return without calling pool_stop
  run _watcher_check_ttl
  [ "$status" -eq 0 ]
  # Pool should still exist
  [ -f "$POOL_DIR/pool.json" ]
}

# ---------------------------------------------------------------------------
# pool_gc
# ---------------------------------------------------------------------------

@test "pool_gc cleans stale pool with dead watcher" {
  local hash="deadbeef"
  local stale_dir="$TEST_DIR/pools/$hash"
  mkdir -p "$stale_dir"
  echo "99999" > "$stale_dir/watcher.pid"
  jq -n '{version:1, project_dir:"/tmp/stale", tmux_socket:"sub-claude-deadbeef"}' \
    > "$stale_dir/pool.json"

  SUB_CLAUDE_STATE_DIR="$TEST_DIR/pools"

  run pool_gc
  [ "$status" -eq 0 ]
  [[ "$output" == *"cleaning stale pool"* ]]
  [ ! -d "$stale_dir" ]
}

@test "pool_gc skips own pool" {
  # Create our own pool directory
  mkdir -p "$POOL_DIR"
  echo "$$" > "$POOL_DIR/watcher.pid"
  jq -n '{version:1, project_dir:"/tmp/self", tmux_socket:"sub-claude-self"}' \
    > "$POOL_DIR/pool.json"

  SUB_CLAUDE_STATE_DIR="$(dirname "$POOL_DIR")"

  run pool_gc
  [ "$status" -eq 0 ]
  # Our pool should still exist
  [ -d "$POOL_DIR" ]
}

@test "pool_gc reports no stale pools when all healthy" {
  SUB_CLAUDE_STATE_DIR="$TEST_DIR/empty-pools"
  mkdir -p "$SUB_CLAUDE_STATE_DIR"

  run pool_gc
  [ "$status" -eq 0 ]
  [[ "$output" == *"no stale pools"* ]]
}

@test "pool_gc cleans pool with no watcher.pid" {
  local hash="aabb1122"
  local stale_dir="$TEST_DIR/pools/$hash"
  mkdir -p "$stale_dir"
  jq -n '{version:1, project_dir:"/tmp/orphan", tmux_socket:"sub-claude-aabb1122"}' \
    > "$stale_dir/pool.json"
  # No watcher.pid file

  SUB_CLAUDE_STATE_DIR="$TEST_DIR/pools"

  run pool_gc
  [ "$status" -eq 0 ]
  [[ "$output" == *"cleaning stale pool"* ]]
  [ ! -d "$stale_dir" ]
}

# ---------------------------------------------------------------------------
# _iso_to_epoch (core.sh)
# ---------------------------------------------------------------------------

@test "_iso_to_epoch parses ISO timestamp correctly" {
  local epoch
  epoch=$(_iso_to_epoch "2026-01-01T00:00:00Z")
  [ "$epoch" -gt 0 ]
  # Should be around 1767225600 (2026-01-01 UTC)
  [ "$epoch" -gt 1700000000 ]
  [ "$epoch" -lt 1800000000 ]
}

@test "_locked_update_last_dispatch_at updates pool.json" {
  jq -n '{version:1, last_dispatch_at: "2020-01-01T00:00:00Z"}' | update_pool_json

  with_pool_lock _locked_update_last_dispatch_at

  local val
  val=$(read_pool_json | jq -r '.last_dispatch_at')
  [ "$val" != "2020-01-01T00:00:00Z" ]
  [ -n "$val" ]
}
