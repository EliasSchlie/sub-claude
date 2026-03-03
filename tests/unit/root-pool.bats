#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2329
# Unit tests for root-level pool enhancement (GitHub issue #25).
#
# Tests cover:
#   - resolve_pool_dir fallback to root pool
#   - resolve_pool_dir prefers project-local pool when it exists
#   - is_root_pool helper
#   - pool_init --local creates project-local pool
#   - pool_init (no --local) creates root pool
#   - pool_list shows TYPE column (root/local)
#   - cwd prepended to prompt for root pool dispatch

load '../helpers/setup'
load '../helpers/mocks'

setup()    { _common_setup;    }
teardown() { _common_teardown; }

# ---------------------------------------------------------------------------
# resolve_pool_dir — root pool fallback
# ---------------------------------------------------------------------------

@test "resolve_pool_dir falls back to root pool when no project-local pool exists" {
  # Ensure no project-local pool.json exists
  rm -f "$POOL_DIR/pool.json"

  POOL_DIR=""
  TMUX_SOCKET=""
  resolve_pool_dir

  [[ "$POOL_DIR" == *"/_root" ]]
  [ "$TMUX_SOCKET" = "sub-claude-root" ]
}

@test "resolve_pool_dir prefers project-local pool when pool.json exists" {
  # Create a project-local pool.json at the expected hash path
  local project_dir
  project_dir=$(get_project_dir)
  local hash
  hash=$(project_hash "$project_dir")
  mkdir -p "$SUB_CLAUDE_STATE_DIR/$hash"
  echo '{"version":1}' > "$SUB_CLAUDE_STATE_DIR/$hash/pool.json"

  POOL_DIR=""
  TMUX_SOCKET=""
  resolve_pool_dir

  [ "$POOL_DIR" = "$SUB_CLAUDE_STATE_DIR/$hash" ]
  [ "$TMUX_SOCKET" = "sub-claude-$hash" ]

  # Clean up
  rm -rf "${SUB_CLAUDE_STATE_DIR:?}/${hash:?}"
}

# ---------------------------------------------------------------------------
# is_root_pool
# ---------------------------------------------------------------------------

@test "is_root_pool returns 0 for root pool" {
  POOL_DIR="$SUB_CLAUDE_STATE_DIR/_root"
  run is_root_pool
  [ "$status" -eq 0 ]
}

@test "is_root_pool returns 1 for project-local pool" {
  POOL_DIR="$SUB_CLAUDE_STATE_DIR/aabb1122"
  run is_root_pool
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# pool_init — root vs --local
# ---------------------------------------------------------------------------

@test "pool_init creates root pool by default" {
  POOL_DIR="$SUB_CLAUDE_STATE_DIR/_root"
  TMUX_SOCKET="sub-claude-root"
  rm -rf "$POOL_DIR"
  mkdir -p "$POOL_DIR/slots" "$POOL_DIR/jobs" "$POOL_DIR/queue"

  run pool_init --size 2
  [ "$status" -eq 0 ]
  [ -f "$POOL_DIR/pool.json" ]

  local pool_type
  pool_type=$(jq -r '.pool_type' "$POOL_DIR/pool.json")
  [ "$pool_type" = "root" ]

  # project_dir should be $HOME for root pool
  local project_dir
  project_dir=$(jq -r '.project_dir' "$POOL_DIR/pool.json")
  [ "$project_dir" = "$HOME" ]
}

@test "pool_init --local creates project-local pool" {
  # Start from root pool dir so --local switches us
  POOL_DIR="$SUB_CLAUDE_STATE_DIR/_root"
  TMUX_SOCKET="sub-claude-root"

  local project_dir
  project_dir=$(get_project_dir)
  local hash
  hash=$(project_hash "$project_dir")

  # Ensure target doesn't exist
  rm -rf "${SUB_CLAUDE_STATE_DIR:?}/${hash:?}"

  run pool_init --local --size 2
  [ "$status" -eq 0 ]
  [ -f "$SUB_CLAUDE_STATE_DIR/$hash/pool.json" ]

  local pool_type
  pool_type=$(jq -r '.pool_type' "$SUB_CLAUDE_STATE_DIR/$hash/pool.json")
  [ "$pool_type" = "local" ]

  # Clean up
  rm -rf "${SUB_CLAUDE_STATE_DIR:?}/${hash:?}"
}

# ---------------------------------------------------------------------------
# pool_list — TYPE column
# ---------------------------------------------------------------------------

@test "pool_list shows TYPE column with root and local" {
  SUB_CLAUDE_STATE_DIR="$TEST_DIR/pools"

  # Create a root pool
  mkdir -p "$SUB_CLAUDE_STATE_DIR/_root"
  jq -n '{version:1, pool_type:"root", project_dir:"/Users/test", pool_size:3, tmux_socket:"sub-claude-root", slots:[]}' \
    > "$SUB_CLAUDE_STATE_DIR/_root/pool.json"

  # Create a local pool
  local hash="aabb1122"
  mkdir -p "$SUB_CLAUDE_STATE_DIR/$hash"
  jq -n '{version:1, pool_type:"local", project_dir:"/tmp/myproject", pool_size:2, tmux_socket:"sub-claude-aabb1122", slots:[]}' \
    > "$SUB_CLAUDE_STATE_DIR/$hash/pool.json"

  run pool_list
  [ "$status" -eq 0 ]
  [[ "$output" == *"TYPE"* ]]
  [[ "$output" == *"root"* ]]
  [[ "$output" == *"local"* ]]
}

@test "pool_list infers type from _root hash for pre-upgrade pools" {
  SUB_CLAUDE_STATE_DIR="$TEST_DIR/pools"

  # Pool without pool_type field but with _root hash
  mkdir -p "$SUB_CLAUDE_STATE_DIR/_root"
  jq -n '{version:1, project_dir:"/Users/test", pool_size:3, tmux_socket:"sub-claude-root", slots:[]}' \
    > "$SUB_CLAUDE_STATE_DIR/_root/pool.json"

  run pool_list
  [ "$status" -eq 0 ]
  [[ "$output" == *"root"* ]]
}

# ---------------------------------------------------------------------------
# cwd in prompt for root pool dispatch
# ---------------------------------------------------------------------------

@test "dispatch_to_slot prepends cwd instruction for root pool" {
  POOL_DIR="$SUB_CLAUDE_STATE_DIR/_root"
  TMUX_SOCKET="sub-claude-root"
  mkdir -p "$POOL_DIR/slots/0" "$POOL_DIR/jobs/a1b2c3d4"

  # Create pool.json with a fresh slot
  jq -n '{version:1, pool_type:"root", pool_size:1, slots:[{index:0, status:"fresh", job_id:null, claude_session_id:null, last_used_at:null}], pins:{}}' \
    | update_pool_json

  # Create job meta with cwd
  jq -n '{id:"a1b2c3d4", prompt:"do stuff", cwd:"/tmp/my-project", status:"queued", depth:0}' \
    > "$POOL_DIR/jobs/a1b2c3d4/meta.json"

  # Track what send_prompt receives
  local captured_prompt=""
  send_prompt() { captured_prompt="$2"; }

  _dispatch_to_slot "a1b2c3d4" 0 "do stuff" new

  # The prompt should contain the cwd instruction
  [[ "$captured_prompt" == *"cd"* ]]
  [[ "$captured_prompt" == *"/tmp/my-project"* ]]
}

@test "dispatch_to_slot does NOT prepend cwd for project-local pool" {
  POOL_DIR="$SUB_CLAUDE_STATE_DIR/aabb1122"
  TMUX_SOCKET="sub-claude-aabb1122"
  mkdir -p "$POOL_DIR/slots/0" "$POOL_DIR/jobs/a1b2c3d4"

  jq -n '{version:1, pool_type:"local", pool_size:1, slots:[{index:0, status:"fresh", job_id:null, claude_session_id:null, last_used_at:null}], pins:{}}' \
    | update_pool_json

  jq -n '{id:"a1b2c3d4", prompt:"do stuff", cwd:"/tmp/my-project", status:"queued", depth:0}' \
    > "$POOL_DIR/jobs/a1b2c3d4/meta.json"

  local captured_prompt=""
  send_prompt() { captured_prompt="$2"; }

  _dispatch_to_slot "a1b2c3d4" 0 "do stuff" new

  # The prompt should NOT contain the cwd instruction for local pools
  [[ "$captured_prompt" != *"IMPORTANT: First run: cd"* ]]
}

# ---------------------------------------------------------------------------
# ensure_pool_exists — messages
# ---------------------------------------------------------------------------

@test "ensure_pool_exists shows root pool hint for root pool" {
  POOL_DIR="$SUB_CLAUDE_STATE_DIR/_root"
  rm -f "$POOL_DIR/pool.json"

  run ensure_pool_exists
  [ "$status" -eq 1 ]
  [[ "$output" == *"root pool"* ]]
}

@test "ensure_pool_exists shows both options for non-root pool" {
  POOL_DIR="$SUB_CLAUDE_STATE_DIR/aabb1122"
  rm -f "$POOL_DIR/pool.json"

  run ensure_pool_exists
  [ "$status" -eq 1 ]
  [[ "$output" == *"--local"* ]]
}
