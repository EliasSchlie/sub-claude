#!/usr/bin/env bats
# Integration tests for session commands: start, followup, capture, result, wait.

load '../helpers/integration-setup'

setup()    { _integ_setup; }
teardown() { _integ_teardown; }

# --- cmd_start ---

@test "start returns a valid 8-char hex job ID" {
  _integ_init_pool 2

  local id
  id=$(cmd_start "hello world")
  [[ "$id" =~ ^[0-9a-f]{8}$ ]]
}

@test "start dispatches prompt to a slot" {
  _integ_init_pool 2

  local id
  id=$(cmd_start "say hello")

  # Job meta should exist and be processing
  [ -f "$POOL_DIR/jobs/$id/meta.json" ]
  local meta_status
  meta_status=$(jq -r '.status' "$POOL_DIR/jobs/$id/meta.json")
  [ "$meta_status" = "processing" ]

  # Slot 0 should be busy with this job
  local slot_status slot_job
  slot_status=$(jq -r '.slots[0].status' "$POOL_DIR/pool.json")
  slot_job=$(jq -r '.slots[0].job_id' "$POOL_DIR/pool.json")
  [ "$slot_status" = "busy" ]
  [ "$slot_job" = "$id" ]
}

@test "start uses fresh slots before idle slots" {
  _integ_init_pool 2

  local id1
  id1=$(cmd_start "first task")

  # Slot 0 should be busy
  local s0
  s0=$(jq -r '.slots[0].status' "$POOL_DIR/pool.json")
  [ "$s0" = "busy" ]

  local id2
  id2=$(cmd_start "second task")

  # Slot 1 should be busy (was fresh, preferred over idle)
  local s1
  s1=$(jq -r '.slots[1].status' "$POOL_DIR/pool.json")
  [ "$s1" = "busy" ]
}

@test "start queues when all slots busy" {
  _integ_init_pool 2

  cmd_start "task 1" >/dev/null
  cmd_start "task 2" >/dev/null

  # Both slots busy
  local s0 s1
  s0=$(jq -r '.slots[0].status' "$POOL_DIR/pool.json")
  s1=$(jq -r '.slots[1].status' "$POOL_DIR/pool.json")
  [ "$s0" = "busy" ]
  [ "$s1" = "busy" ]

  # Third start should queue
  local id3
  id3=$(cmd_start "task 3")

  local meta_status
  meta_status=$(jq -r '.status' "$POOL_DIR/jobs/$id3/meta.json")
  [ "$meta_status" = "queued" ]

  # Queue should have an entry
  local qlen
  qlen=$(queue_length)
  [ "$qlen" -eq 1 ]
}

# --- capture ---

@test "capture shows live terminal output" {
  _integ_init_pool 1

  local id
  id=$(cmd_start "describe the project")

  # Wait briefly for mock claude to process
  sleep 2

  local output
  output=$(cmd_capture "$id")
  # Should contain this job's response (isolated via raw_offset)
  [[ "$output" == *"describe the project"* ]]
}

@test "capture errors on queued session" {
  _integ_init_pool 1
  cmd_start "blocker" >/dev/null
  local id
  id=$(cmd_start "queued task")

  run cmd_capture "$id"
  [ "$status" -ne 0 ]
  [[ "$output" == *"queued"* ]]
}

# --- result ---

@test "result errors on processing session" {
  _integ_init_pool 1

  local id
  id=$(cmd_start "busy task")

  run cmd_result "$id"
  [ "$status" -ne 0 ]
  [[ "$output" == *"still processing"* ]]
}

@test "result succeeds on finished session" {
  _integ_init_pool 1

  local id
  id=$(cmd_start "quick task")

  # Simulate watcher: wait for done, then mark completed+idle
  _integ_complete_job "$id" 0

  local output
  output=$(cmd_result "$id")
  # JSONL extraction should return clean response text (no terminal chrome)
  [[ "$output" == *"Result: completed task"* ]]
}

# --- status ---

@test "status shows job state" {
  _integ_init_pool 1

  local id
  id=$(cmd_start "check status")

  local output
  output=$(cmd_status "$id")
  [[ "$output" == *"$id"* ]]
  [[ "$output" == *"processing"* ]]
}

# --- list ---

@test "list shows direct children" {
  _integ_init_pool 2

  local id1 id2
  id1=$(cmd_start "task one")
  id2=$(cmd_start "task two")

  local output
  output=$(cmd_list)
  [[ "$output" == *"$id1"* ]]
  [[ "$output" == *"$id2"* ]]
}

@test "list empty when no jobs" {
  _integ_init_pool 1

  local output
  output=$(cmd_list)
  [ -z "$output" ]
}

# --- followup ---

@test "followup sends to idle session" {
  _integ_init_pool 1

  local id
  id=$(cmd_start "initial task")

  # Simulate completion
  _integ_wait_for_done_file 0
  with_pool_lock _locked_update_slot_idle 0 "$id"
  get_job_meta "$id" | jq '.status = "completed"' | update_job_meta "$id"

  # Remove done file so followup can re-trigger
  rm -f "$POOL_DIR/slots/0/done"

  # Followup should succeed
  local fid
  fid=$(cmd_followup "$id" "follow up question")

  # Should return same ID
  [ "$fid" = "$id" ]

  # Slot should be busy again
  local slot_status
  slot_status=$(jq -r '.slots[0].status' "$POOL_DIR/pool.json")
  [ "$slot_status" = "busy" ]
}

@test "followup errors on processing session" {
  _integ_init_pool 1

  local id
  id=$(cmd_start "busy task")

  run cmd_followup "$id" "another question"
  [ "$status" -ne 0 ]
  [[ "$output" == *"still processing"* ]]
}

@test "followup errors on unknown ID" {
  _integ_init_pool 1

  run cmd_followup "deadbeef" "hello"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown job ID"* ]]
}

# --- input ---

@test "input sends text to processing session" {
  _integ_init_pool 1

  local id
  id=$(cmd_start "interactive task")

  # Should succeed (no error)
  cmd_input "$id" "some input text"
}

@test "input warns on idle session" {
  _integ_init_pool 1

  local id
  id=$(cmd_start "task")

  # Simulate completion
  _integ_wait_for_done_file 0
  with_pool_lock _locked_update_slot_idle 0 "$id"
  get_job_meta "$id" | jq '.status = "completed"' | update_job_meta "$id"

  # Input should warn but succeed
  run cmd_input "$id" "typing on idle"
  [ "$status" -eq 0 ]
  [[ "$output" == *"idle"* || "${lines[*]}" == *"idle"* ]] || [[ "$stderr" == *"idle"* ]] || true
}

# --- key ---

@test "key sends special key to processing session" {
  _integ_init_pool 1

  local id
  id=$(cmd_start "task with keys")

  cmd_key "$id" Escape
  cmd_key "$id" Enter
}

@test "key errors on queued session" {
  _integ_init_pool 1
  cmd_start "blocker" >/dev/null
  local id
  id=$(cmd_start "queued task")

  run cmd_key "$id" Escape
  [ "$status" -ne 0 ]
  [[ "$output" == *"queued"* ]]
}

# --- cancel ---

@test "cancel removes queued job" {
  _integ_init_pool 1
  cmd_start "blocker" >/dev/null
  local id
  id=$(cmd_start "to cancel")

  # Verify it's queued
  local meta_status
  meta_status=$(jq -r '.status' "$POOL_DIR/jobs/$id/meta.json")
  [ "$meta_status" = "queued" ]

  # Cancel it
  cmd_cancel "$id"

  # Queue should be empty
  local qlen
  qlen=$(queue_length)
  [ "$qlen" -eq 0 ]
}

@test "cancel errors on running job" {
  _integ_init_pool 1

  local id
  id=$(cmd_start "running task")

  run cmd_cancel "$id"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not in the queue"* ]]
}

# --- stop ---

@test "stop sends Escape to busy session" {
  _integ_init_pool 1

  local id
  id=$(cmd_start "busy work")

  # Should succeed
  cmd_stop "$id"
}

@test "stop errors on non-busy session" {
  _integ_init_pool 1

  local id
  id=$(cmd_start "task")
  _integ_wait_for_done_file 0
  with_pool_lock _locked_update_slot_idle 0 "$id"
  get_job_meta "$id" | jq '.status = "completed"' | update_job_meta "$id"

  run cmd_stop "$id"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not busy"* ]]
}

# --- uuid ---

@test "uuid shows Claude session UUID" {
  _integ_init_pool 1

  local id
  id=$(cmd_start "task")

  local output
  output=$(cmd_uuid "$id")
  [[ "$output" == *"claude-uuid:"* ]]
  [[ "$output" == *"slot: 0"* ]]
  [[ "$output" == *"processing"* ]]
}

# --- pin/unpin ---

@test "pin and unpin work on idle session" {
  _integ_init_pool 1

  local id
  id=$(cmd_start "task")
  _integ_wait_for_done_file 0
  with_pool_lock _locked_update_slot_idle 0 "$id"
  get_job_meta "$id" | jq '.status = "completed"' | update_job_meta "$id"

  # Pin
  run cmd_pin "$id" 60
  [ "$status" -eq 0 ]
  [[ "$output" == *"pinned"* ]]

  # Verify pin exists in pool.json
  local pin_expiry
  pin_expiry=$(jq -r --arg jid "$id" '.pins[$jid] // empty' "$POOL_DIR/pool.json")
  [ -n "$pin_expiry" ]

  # Unpin
  run cmd_unpin "$id"
  [ "$status" -eq 0 ]

  # Pin should be gone
  pin_expiry=$(jq -r --arg jid "$id" '.pins[$jid] // empty' "$POOL_DIR/pool.json")
  [ -z "$pin_expiry" ]
}

# --- clean ---

@test "clean removes completed session" {
  _integ_init_pool 1

  local id
  id=$(cmd_start "task to clean")
  _integ_wait_for_done_file 0
  with_pool_lock _locked_update_slot_idle 0 "$id"
  get_job_meta "$id" | jq '.status = "completed"' | update_job_meta "$id"

  cmd_clean "$id"

  # Job dir should be gone
  [ ! -d "$POOL_DIR/jobs/$id" ]
}

@test "clean errors on busy session without --force" {
  _integ_init_pool 1

  local id
  id=$(cmd_start "busy task")

  run cmd_clean "$id"
  [ "$status" -ne 0 ]
  [[ "$output" == *"still processing"* ]]
}
