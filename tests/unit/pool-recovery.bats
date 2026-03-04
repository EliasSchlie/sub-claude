#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2329
# Unit tests for auto-recovery of unhealthy pools (issue #38).
#
# _ensure_pool_healthy() detects dead watchers and dead tmux servers
# and recovers transparently before dispatching work.

load '../helpers/setup'
load '../helpers/mocks'

setup()    { _common_setup;    }
teardown() { _common_teardown; }

# ---------------------------------------------------------------------------
# Helper: create a minimal valid pool.json so _require_pool passes
# ---------------------------------------------------------------------------
_create_pool_json() {
  local size="${1:-4}"
  local slots="[]"
  local i=0
  while [ "$i" -lt "$size" ]; do
    slots=$(printf '%s' "$slots" | jq \
      --argjson idx "$i" \
      '. + [{"index": $idx, "status": "fresh", "job_id": null, "claude_session_id": "uuid-'$i'"}]')
    mkdir -p "$POOL_DIR/slots/$i"
    touch "$POOL_DIR/slots/$i/run.sh"
    i=$(( i + 1 ))
  done

  jq -n \
    --argjson size "$size" \
    --argjson slots "$slots" \
    --arg socket "$TMUX_SOCKET" \
    --arg project_dir "$TEST_DIR" \
    '{
      pool_size: $size,
      slots: $slots,
      tmux_socket: $socket,
      project_dir: $project_dir,
      idle_timeout: 1800,
      ttl: 7200,
      last_activity_at: null,
      pins: {}
    }' | update_pool_json
}

# ---------------------------------------------------------------------------
# _ensure_pool_healthy — healthy pool
# ---------------------------------------------------------------------------

@test "_ensure_pool_healthy returns 0 when pool is running" {
  _create_pool_json

  # Mock: pool is running (watcher + tmux alive)
  is_pool_running() { return 0; }

  run _ensure_pool_healthy
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# _ensure_pool_healthy — watcher dead, tmux alive
# ---------------------------------------------------------------------------

@test "_ensure_pool_healthy restarts watcher when tmux is alive but watcher is dead" {
  _create_pool_json

  # Mock: pool not running (watcher dead)
  is_pool_running() { return 1; }

  # Mock: tmux server is alive
  tmux_cmd() {
    case "$1" in
      has-session) return 0 ;;
      *) return 0 ;;
    esac
  }

  # Track watcher_start calls
  local watcher_started="$TEST_DIR/watcher_started"
  watcher_start() { touch "$watcher_started"; }

  run _ensure_pool_healthy
  [ "$status" -eq 0 ]
  [ -f "$watcher_started" ]
  [[ "$output" == *"watcher stopped"* ]]
}

# ---------------------------------------------------------------------------
# _ensure_pool_healthy — both dead
# ---------------------------------------------------------------------------

@test "_ensure_pool_healthy returns 1 when tmux server is also dead" {
  _create_pool_json

  # Mock: pool not running
  is_pool_running() { return 1; }

  # Mock: tmux server is dead
  tmux_cmd() {
    case "$1" in
      has-session) return 1 ;;
      *) return 0 ;;
    esac
  }

  run _ensure_pool_healthy
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# _ensure_pool_healthy — watcher_start failure falls back to reinit
# ---------------------------------------------------------------------------

@test "_ensure_pool_healthy returns 1 when watcher_start fails" {
  _create_pool_json

  is_pool_running() { return 1; }
  tmux_cmd() {
    case "$1" in
      has-session) return 0 ;;
      *) return 0 ;;
    esac
  }

  # watcher_start fails
  watcher_start() { return 1; }

  run _ensure_pool_healthy
  [ "$status" -eq 1 ]
  [[ "$output" == *"watcher restart failed"* ]]
}

# ---------------------------------------------------------------------------
# cmd_followup — health check
# ---------------------------------------------------------------------------

@test "cmd_followup dies with guidance when pool is fully dead" {
  _create_pool_json

  is_pool_running() { return 1; }
  tmux_cmd() {
    case "$1" in
      has-session) return 1 ;;
      *) return 0 ;;
    esac
  }

  # Create a completed job so followup has something to target
  local job_id="deadbeef"
  mkdir -p "$POOL_DIR/jobs/$job_id"
  jq -n '{id: "deadbeef", status: "completed", claude_session_id: "uuid-1", prompt: "test"}' \
    > "$POOL_DIR/jobs/$job_id/meta.json"

  run cmd_followup "$job_id" "follow up prompt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"pool unhealthy"* ]]
  [[ "$output" == *"pool stop"* ]]
}

# ---------------------------------------------------------------------------
# cmd_start — auto-recovery: watcher restart
# ---------------------------------------------------------------------------

@test "cmd_start recovers when watcher is dead but tmux is alive" {
  _create_pool_json

  # First call: unhealthy. After recovery: healthy.
  local call_count="$TEST_DIR/is_pool_running_calls"
  echo "0" > "$call_count"
  is_pool_running() {
    local n
    n=$(cat "$call_count")
    echo "$(( n + 1 ))" > "$call_count"
    [ "$n" -gt 0 ] && return 0  # healthy after recovery
    return 1  # unhealthy on first check
  }

  # tmux alive
  tmux_cmd() {
    case "$1" in
      has-session) return 0 ;;
      *) return 0 ;;
    esac
  }

  local watcher_started="$TEST_DIR/watcher_started"
  watcher_start() { touch "$watcher_started"; }

  run cmd_start "test prompt"
  [ "$status" -eq 0 ]
  [ -f "$watcher_started" ]
  # Should output a job ID (8 hex chars)
  [[ "$output" =~ [0-9a-f]{8} ]]
}

# ---------------------------------------------------------------------------
# cmd_start — auto-recovery: full reinit
# ---------------------------------------------------------------------------

@test "cmd_start does full reinit when both watcher and tmux are dead" {
  _create_pool_json

  # Pool is unhealthy
  is_pool_running() { return 1; }

  # tmux server is dead
  tmux_cmd() {
    case "$1" in
      has-session) return 1 ;;
      kill-server) return 0 ;;
      *) return 0 ;;
    esac
  }

  # Track that pool_stop was called
  local stop_called="$TEST_DIR/pool_stop_called"
  pool_stop() { touch "$stop_called"; }

  # Track that _auto_init_pool was called
  local init_called="$TEST_DIR/auto_init_called"
  _auto_init_pool() { touch "$init_called"; echo "$1"; }

  run cmd_start "test prompt"
  [ "$status" -eq 0 ]
  [ -f "$stop_called" ]
  [ -f "$init_called" ]
  [[ "$output" =~ [0-9a-f]{8} ]]
}

# ---------------------------------------------------------------------------
# cmd_start --block degraded during full reinit
# ---------------------------------------------------------------------------

@test "cmd_start --block degrades to non-blocking during full reinit" {
  _create_pool_json

  is_pool_running() { return 1; }
  tmux_cmd() {
    case "$1" in
      has-session) return 1 ;;
      *) return 0 ;;
    esac
  }
  pool_stop() { return 0; }
  _auto_init_pool() { echo "$1"; }

  run cmd_start --block "test prompt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"reinit"* ]] || [[ "${output}" == *"non-blocking"* ]]
}
