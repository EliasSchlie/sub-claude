#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2329
# Unit tests for auto-init improvements:
#   - SUB_CLAUDE_DEFAULT_POOL_SIZE constant shared across pool_init + _auto_init_pool
#   - ensure_pool_exists_or_wait tolerates the auto-init race window

load '../helpers/setup'
load '../helpers/mocks'

setup()    { _common_setup;    }
teardown() { _common_teardown; }

# ---------------------------------------------------------------------------
# SUB_CLAUDE_DEFAULT_POOL_SIZE constant
# ---------------------------------------------------------------------------

@test "SUB_CLAUDE_DEFAULT_POOL_SIZE is defined" {
  [ -n "$SUB_CLAUDE_DEFAULT_POOL_SIZE" ]
}

@test "SUB_CLAUDE_DEFAULT_POOL_SIZE is a positive integer" {
  [[ "$SUB_CLAUDE_DEFAULT_POOL_SIZE" =~ ^[0-9]+$ ]]
  [ "$SUB_CLAUDE_DEFAULT_POOL_SIZE" -gt 0 ]
}

@test "_auto_init_pool message uses SUB_CLAUDE_DEFAULT_POOL_SIZE" {
  # Override to a distinctive value so we can detect it in output.
  SUB_CLAUDE_DEFAULT_POOL_SIZE=42

  # _auto_init_pool needs a job_id and prompt; it will try to launch
  # 'sub-claude pool init' in background — mock that away.
  sub-claude() { return 0; }
  export -f sub-claude

  run _auto_init_pool "deadbeef" "test prompt"
  [[ "$output" == *"42 slots"* ]]
}

# ---------------------------------------------------------------------------
# ensure_pool_exists_or_wait — spin-wait variant for auto-init race
# ---------------------------------------------------------------------------

@test "ensure_pool_exists_or_wait dies immediately when no queue dir exists" {
  rm -f "$POOL_DIR/pool.json"
  rm -rf "$POOL_DIR/queue"
  run ensure_pool_exists_or_wait 5
  [ "$status" -eq 1 ]
  [[ "$output" == *"no pool found"* ]]
}

@test "ensure_pool_exists_or_wait succeeds immediately when pool.json exists" {
  echo '{"version":1}' | update_pool_json
  run ensure_pool_exists_or_wait 5
  [ "$status" -eq 0 ]
}

@test "ensure_pool_exists_or_wait fails after timeout when pool.json never appears" {
  rm -f "$POOL_DIR/pool.json"
  run ensure_pool_exists_or_wait 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"timed out"* ]]
}

@test "ensure_pool_exists_or_wait succeeds when pool.json appears mid-wait" {
  rm -f "$POOL_DIR/pool.json"

  # Create pool.json after a short delay in the background.
  ( sleep 1; echo '{"version":1}' > "$POOL_DIR/pool.json" ) &

  run ensure_pool_exists_or_wait 5
  [ "$status" -eq 0 ]
}
