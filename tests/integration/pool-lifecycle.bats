#!/usr/bin/env bats
# Integration tests for pool lifecycle: init, stop, status, resize, double-init.

load '../helpers/integration-setup'

setup()    { _integ_setup; }
teardown() { _integ_teardown; }

# --- pool init ---

@test "pool init creates tmux server and slots" {
  _integ_init_pool 2

  # tmux server should be running
  tmux_cmd has-session -t pool

  # pool.json should exist with correct structure
  [ -f "$POOL_DIR/pool.json" ]
  local pool_size
  pool_size=$(jq -r '.pool_size' "$POOL_DIR/pool.json")
  [ "$pool_size" -eq 2 ]

  # Both slots should be fresh
  local s0 s1
  s0=$(jq -r '.slots[] | select(.index == 0) | .status' "$POOL_DIR/pool.json")
  s1=$(jq -r '.slots[] | select(.index == 1) | .status' "$POOL_DIR/pool.json")
  [ "$s0" = "fresh" ]
  [ "$s1" = "fresh" ]

  # Each slot should have a claude_session_id (UUID)
  local uuid0
  uuid0=$(jq -r '.slots[] | select(.index == 0) | .claude_session_id' "$POOL_DIR/pool.json")
  [ -n "$uuid0" ]
  [ "$uuid0" != "null" ]
}

@test "pool init creates slot directories" {
  _integ_init_pool 2

  [ -d "$POOL_DIR/slots/0" ]
  [ -d "$POOL_DIR/slots/1" ]
  [ -f "$POOL_DIR/slots/0/run.sh" ]
  [ -f "$POOL_DIR/slots/1/run.sh" ]
}

@test "pool init with custom size" {
  _integ_init_pool 3

  local pool_size slot_count
  pool_size=$(jq -r '.pool_size' "$POOL_DIR/pool.json")
  slot_count=$(jq '.slots | length' "$POOL_DIR/pool.json")
  [ "$pool_size" -eq 3 ]
  [ "$slot_count" -eq 3 ]
}

@test "pool init rejects zero size" {
  run pool_init --size 0
  [ "$status" -ne 0 ]
  [[ "$output" == *"positive integer"* ]]
}

@test "pool init rejects non-numeric size" {
  run pool_init --size abc
  [ "$status" -ne 0 ]
  [[ "$output" == *"positive integer"* ]]
}

@test "double pool init fails" {
  _integ_init_pool 2
  run pool_init --size 2
  [ "$status" -ne 0 ]
  [[ "$output" == *"already initialized"* ]]
}

# --- pool stop ---

@test "pool stop kills tmux server" {
  _integ_init_pool 2

  # Server is running
  tmux_cmd has-session -t pool

  pool_stop

  # Server should be gone
  run tmux_cmd has-session -t pool
  [ "$status" -ne 0 ]
}

@test "pool stop removes state directory" {
  _integ_init_pool 2
  [ -f "$POOL_DIR/pool.json" ]

  pool_stop

  [ ! -d "$POOL_DIR" ]
}

@test "pool init works after pool stop" {
  _integ_init_pool 2
  pool_stop

  # Re-create the directory structure that _integ_init_pool expects
  mkdir -p "$POOL_DIR/slots" "$POOL_DIR/jobs" "$POOL_DIR/queue"

  _integ_init_pool 2

  # Pool should be fully functional again
  local pool_size
  pool_size=$(jq -r '.pool_size' "$POOL_DIR/pool.json")
  [ "$pool_size" -eq 2 ]
}

# --- pool status ---

@test "pool status shows slots and queue" {
  _integ_init_pool 2

  run pool_status
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 slots"* ]]
  [[ "$output" == *"Slots:"* ]]
  [[ "$output" == *"Queue: 0 pending"* ]]
  [[ "$output" == *"Pins: 0 active"* ]]
}

# --- pool resize ---

@test "pool resize grows pool" {
  _integ_init_pool 2

  pool_resize 3

  local pool_size slot_count
  pool_size=$(jq -r '.pool_size' "$POOL_DIR/pool.json")
  slot_count=$(jq '.slots | length' "$POOL_DIR/pool.json")
  [ "$pool_size" -eq 3 ]
  [ "$slot_count" -eq 3 ]

  # New slot should be fresh
  local s2
  s2=$(jq -r '.slots[] | select(.index == 2) | .status' "$POOL_DIR/pool.json")
  [ "$s2" = "fresh" ]
}

@test "pool resize shrinks pool" {
  _integ_init_pool 3

  pool_resize 2

  local pool_size
  pool_size=$(jq -r '.pool_size' "$POOL_DIR/pool.json")
  [ "$pool_size" -eq 2 ]

  # Excess slot should be decommissioning
  local s2
  s2=$(jq -r '.slots[] | select(.index == 2) | .status' "$POOL_DIR/pool.json")
  [ "$s2" = "decommissioning" ]
}

@test "pool resize to same size is no-op" {
  _integ_init_pool 2

  run pool_resize 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"already at 2"* ]]
}

# --- tmux pane health ---

@test "mock claude panes are alive after init" {
  _integ_init_pool 2

  is_pane_alive 0
  is_pane_alive 1
}

@test "mock claude accepted trust prompt" {
  _integ_init_pool 1

  # Capture pane — should show "Claude Code ready" (trust prompt accepted)
  local output
  output=$(capture_pane 0)
  [[ "$output" == *"Claude Code ready"* ]]
}

@test "slot wrapper exports correct env vars" {
  _integ_init_pool 1

  # Check the generated run.sh contains expected exports
  local wrapper="$POOL_DIR/slots/0/run.sh"
  [[ -f "$wrapper" ]]
  grep -q "CLAUDE_POOL=1" "$wrapper"
  grep -q "CLAUDE_POOL_SLOT=0" "$wrapper"
  grep -q "CLAUDE_POOL_DONE_FILE=" "$wrapper"
  grep -q "CLAUDE_BELL_OFF=1" "$wrapper"
}
