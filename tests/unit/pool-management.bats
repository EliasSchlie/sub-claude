#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2329
# Unit tests for pool list, pool destroy, and pool migrate commands.
# Covers GitHub issues #10 and #11.

load '../helpers/setup'
load '../helpers/mocks'

setup()    { _common_setup;    }
teardown() { _common_teardown; }

# ---------------------------------------------------------------------------
# pool_list (#10)
# ---------------------------------------------------------------------------

@test "pool_list shows pools with project dir and slot count" {
  # Setup: create a fake pool at a known hash
  local hash="aabb1122"
  local pool_path="$TEST_DIR/pools/$hash"
  mkdir -p "$pool_path"
  jq -n '{version:1, project_dir:"/tmp/myproject", pool_size:3, tmux_socket:"sub-claude-aabb1122", slots:[{index:0},{index:1},{index:2}]}' \
    > "$pool_path/pool.json"

  # Override state dir to our test dir
  SUB_CLAUDE_STATE_DIR="$TEST_DIR/pools"

  run pool_list
  [ "$status" -eq 0 ]
  [[ "$output" == *"aabb1122"* ]]
  [[ "$output" == *"/tmp/myproject"* ]]
  [[ "$output" == *"3"* ]]
}

@test "pool_list shows 'no pools found' when none exist" {
  SUB_CLAUDE_STATE_DIR="$TEST_DIR/empty-pools"
  mkdir -p "$SUB_CLAUDE_STATE_DIR"

  run pool_list
  [ "$status" -eq 0 ]
  [[ "$output" == *"no pools found"* ]]
}

@test "pool_list shows multiple pools" {
  SUB_CLAUDE_STATE_DIR="$TEST_DIR/pools"

  local hash1="aabb1122"
  mkdir -p "$SUB_CLAUDE_STATE_DIR/$hash1"
  jq -n '{version:1, project_dir:"/tmp/project-a", pool_size:2, tmux_socket:"sub-claude-aabb1122", slots:[{index:0},{index:1}]}' \
    > "$SUB_CLAUDE_STATE_DIR/$hash1/pool.json"

  local hash2="ccdd3344"
  mkdir -p "$SUB_CLAUDE_STATE_DIR/$hash2"
  jq -n '{version:1, project_dir:"/tmp/project-b", pool_size:5, tmux_socket:"sub-claude-ccdd3344", slots:[{index:0},{index:1},{index:2},{index:3},{index:4}]}' \
    > "$SUB_CLAUDE_STATE_DIR/$hash2/pool.json"

  run pool_list
  [ "$status" -eq 0 ]
  [[ "$output" == *"aabb1122"* ]]
  [[ "$output" == *"ccdd3344"* ]]
  [[ "$output" == *"/tmp/project-a"* ]]
  [[ "$output" == *"/tmp/project-b"* ]]
}

@test "pool_list shows watcher status" {
  SUB_CLAUDE_STATE_DIR="$TEST_DIR/pools"
  local hash="aabb1122"
  mkdir -p "$SUB_CLAUDE_STATE_DIR/$hash"
  jq -n '{version:1, project_dir:"/tmp/proj", pool_size:2, tmux_socket:"sub-claude-aabb1122", slots:[]}' \
    > "$SUB_CLAUDE_STATE_DIR/$hash/pool.json"

  # No watcher.pid => stopped
  run pool_list
  [ "$status" -eq 0 ]
  [[ "$output" == *"stopped"* ]]
}

# ---------------------------------------------------------------------------
# pool_destroy (#10)
# ---------------------------------------------------------------------------

@test "pool_destroy removes a pool by hash" {
  SUB_CLAUDE_STATE_DIR="$TEST_DIR/pools"
  local hash="aabb1122"
  local pool_path="$SUB_CLAUDE_STATE_DIR/$hash"
  mkdir -p "$pool_path/slots" "$pool_path/jobs"
  jq -n '{version:1, project_dir:"/tmp/proj", pool_size:2, tmux_socket:"sub-claude-aabb1122", slots:[]}' \
    > "$pool_path/pool.json"

  run pool_destroy "$hash"
  [ "$status" -eq 0 ]
  [ ! -d "$pool_path" ]
  [[ "$output" == *"destroyed"* ]]
}

@test "pool_destroy rejects nonexistent hash" {
  SUB_CLAUDE_STATE_DIR="$TEST_DIR/pools"
  mkdir -p "$SUB_CLAUDE_STATE_DIR"

  run pool_destroy "deadbeef"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no pool found"* ]]
}

@test "pool_destroy requires a hash argument" {
  run pool_destroy
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage"*  || "$output" == *"required"* ]]
}

@test "pool_destroy --all removes all pools" {
  SUB_CLAUDE_STATE_DIR="$TEST_DIR/pools"

  local hash1="aabb1122"
  mkdir -p "$SUB_CLAUDE_STATE_DIR/$hash1/slots"
  jq -n '{version:1, project_dir:"/tmp/proj-a", pool_size:2, tmux_socket:"sub-claude-aabb1122", slots:[]}' \
    > "$SUB_CLAUDE_STATE_DIR/$hash1/pool.json"

  local hash2="ccdd3344"
  mkdir -p "$SUB_CLAUDE_STATE_DIR/$hash2/slots"
  jq -n '{version:1, project_dir:"/tmp/proj-b", pool_size:3, tmux_socket:"sub-claude-ccdd3344", slots:[]}' \
    > "$SUB_CLAUDE_STATE_DIR/$hash2/pool.json"

  run pool_destroy --all
  [ "$status" -eq 0 ]
  [ ! -d "$SUB_CLAUDE_STATE_DIR/$hash1" ]
  [ ! -d "$SUB_CLAUDE_STATE_DIR/$hash2" ]
  [[ "$output" == *"destroyed"* ]]
}

@test "pool_destroy --all with no pools reports nothing to destroy" {
  SUB_CLAUDE_STATE_DIR="$TEST_DIR/empty-pools"
  mkdir -p "$SUB_CLAUDE_STATE_DIR"

  run pool_destroy --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"no pools"* ]]
}

@test "pool_destroy kills watcher if running" {
  SUB_CLAUDE_STATE_DIR="$TEST_DIR/pools"
  local hash="aabb1122"
  local pool_path="$SUB_CLAUDE_STATE_DIR/$hash"
  mkdir -p "$pool_path/slots"
  jq -n '{version:1, project_dir:"/tmp/proj", pool_size:2, tmux_socket:"sub-claude-aabb1122", slots:[]}' \
    > "$pool_path/pool.json"

  # Create a fake watcher process (sleep in background)
  sleep 300 &
  local fake_pid=$!
  echo "$fake_pid" > "$pool_path/watcher.pid"

  run pool_destroy "$hash"
  [ "$status" -eq 0 ]

  # Watcher process should have been killed
  run ! kill -0 "$fake_pid" 2>/dev/null

}

# ---------------------------------------------------------------------------
# pool_migrate (#11)
# ---------------------------------------------------------------------------

@test "pool_migrate cleans up old ~/.claude-pool directory" {
  # Create fake old directory
  local old_dir="$TEST_DIR/fake-home/.claude-pool"
  mkdir -p "$old_dir/pools/somehash"
  touch "$old_dir/pools/somehash/pool.json"

  # Override HOME so pool_migrate looks in our test dir
  HOME="$TEST_DIR/fake-home" run pool_migrate
  [ "$status" -eq 0 ]
  [ ! -d "$old_dir" ]
  [[ "$output" == *"cleaned"* || "$output" == *"removed"* ]]
}

@test "pool_migrate removes old binary at ~/.local/bin/claude-pool" {
  local old_bin="$TEST_DIR/fake-home/.local/bin/claude-pool"
  mkdir -p "$(dirname "$old_bin")"
  touch "$old_bin"
  chmod +x "$old_bin"

  HOME="$TEST_DIR/fake-home" run pool_migrate
  [ "$status" -eq 0 ]
  [ ! -f "$old_bin" ]
}

@test "pool_migrate reports when nothing to clean" {
  local fake_home="$TEST_DIR/fake-home-clean"
  mkdir -p "$fake_home"

  HOME="$fake_home" run pool_migrate
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing"* || "$output" == *"clean"* ]]
}

# ---------------------------------------------------------------------------
# pool_init migration warning (#11)
# ---------------------------------------------------------------------------

@test "pool_init warns when old ~/.claude-pool directory exists" {
  local fake_home="$TEST_DIR/fake-home"
  mkdir -p "$fake_home/.claude-pool"

  # pool_init will die because pool already exists (we have pool.json in test setup)
  # So we just check the migration check function directly
  HOME="$fake_home" run _check_old_claude_pool
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude-pool"* ]]
  [[ "$output" == *"migrate"* ]]
}

@test "_check_old_claude_pool is silent when no old directory" {
  local fake_home="$TEST_DIR/fake-home-clean"
  mkdir -p "$fake_home"

  HOME="$fake_home" run _check_old_claude_pool
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
