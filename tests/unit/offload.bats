#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031
# Unit tests for config/lib/sub-claude/offload.sh

load '../helpers/setup'
load '../helpers/mocks'

setup() {
  _common_setup

  # Create pool with 2 slots: slot 0 idle (job loaded), slot 1 fresh
  jq -n '{
    version: 1,
    pool_size: 2,
    queue_seq: 0,
    slots: [
      {"index":0,"status":"idle","job_id":"aabbccdd","claude_session_id":"uuid-1","last_used_at":"2026-01-01T00:00:00Z"},
      {"index":1,"status":"fresh","job_id":null,"claude_session_id":"uuid-2","last_used_at":null}
    ],
    pins: {}
  }' | update_pool_json

  # Create job metadata for slot 0's current job
  mkdir -p "$POOL_DIR/jobs/aabbccdd"
  echo '{"id":"aabbccdd","status":"completed","offloaded":false}' > "$POOL_DIR/jobs/aabbccdd/meta.json"
}

teardown() { _common_teardown; }

# ---------------------------------------------------------------------------
# take_snapshot
# ---------------------------------------------------------------------------

@test "take_snapshot creates snapshot.log for the job" {
  take_snapshot "aabbccdd" 0
  [ -f "$POOL_DIR/jobs/aabbccdd/snapshot.log" ]
}

@test "take_snapshot captures mock pane content into snapshot.log" {
  take_snapshot "aabbccdd" 0
  grep -q "mock pane output" "$POOL_DIR/jobs/aabbccdd/snapshot.log"
}

@test "take_snapshot creates job directory if missing" {
  rm -rf "$POOL_DIR/jobs/aabbccdd"
  take_snapshot "aabbccdd" 0
  [ -d "$POOL_DIR/jobs/aabbccdd" ]
  [ -f "$POOL_DIR/jobs/aabbccdd/snapshot.log" ]
}

@test "take_snapshot uses capture_raw_log when raw.log is available" {
  # Set up a raw.log for slot 0
  mkdir -p "$POOL_DIR/slots/0"
  printf 'prefix content' > "$POOL_DIR/slots/0/raw.log"
  printf 'full raw log output from TUI' >> "$POOL_DIR/slots/0/raw.log"

  # Save offset past the prefix
  printf '14' > "$POOL_DIR/jobs/aabbccdd/raw_offset"

  take_snapshot "aabbccdd" 0
  # Should contain raw log content, not mock pane output
  grep -q "full raw log output from TUI" "$POOL_DIR/jobs/aabbccdd/snapshot.log"
  run ! grep -q "mock pane output" "$POOL_DIR/jobs/aabbccdd/snapshot.log"
}

@test "take_snapshot falls back to capture_pane when raw.log is missing" {
  # No raw.log exists — should fall back to capture_pane mock
  take_snapshot "aabbccdd" 0
  grep -q "mock pane output" "$POOL_DIR/jobs/aabbccdd/snapshot.log"
}

# ---------------------------------------------------------------------------
# offload_to_new
# ---------------------------------------------------------------------------

@test "offload_to_new produces no stdout" {
  output=$(offload_to_new 0)
  [ -z "$output" ]
}

@test "offload_to_new marks existing job as offloaded" {
  offload_to_new 0
  offloaded=$(jq -r '.offloaded' "$POOL_DIR/jobs/aabbccdd/meta.json")
  [ "$offloaded" = "true" ]
}

@test "offload_to_new transitions slot to fresh" {
  offload_to_new 0
  slot_status=$(read_pool_json | jq -r '.slots[0].status')
  [ "$slot_status" = "fresh" ]
}

@test "offload_to_new clears job_id on slot" {
  offload_to_new 0
  slot_jid=$(read_pool_json | jq -r '.slots[0].job_id')
  [ "$slot_jid" = "null" ]
}

@test "offload_to_new creates snapshot.log" {
  offload_to_new 0
  [ -f "$POOL_DIR/jobs/aabbccdd/snapshot.log" ]
}

@test "offload_to_new sets new claude_session_id from extract_uuid mock" {
  offload_to_new 0
  uuid=$(read_pool_json | jq -r '.slots[0].claude_session_id')
  [ "$uuid" = "550e8400-e29b-41d4-a716-446655440000" ]
}

@test "offload_to_new clears tmux scrollback history for the correct slot" {
  # Override tmux_cmd to track calls
  local call_log="$TEST_DIR/tmux_calls.log"
  # shellcheck disable=SC2329
  tmux_cmd() { echo "$*" >> "$call_log"; }
  # Re-override capture_pane mocks that depend on tmux_cmd
  # shellcheck disable=SC2329
  capture_pane()        { echo "mock pane output"; }
  # shellcheck disable=SC2329
  capture_pane_recent() { echo "mock recent output"; }
  # shellcheck disable=SC2329
  extract_uuid()        { echo "550e8400-e29b-41d4-a716-446655440000"; }

  offload_to_new 0

  # Verify clear-history was called for slot-0 with the correct target
  grep -q "clear-history -t pool:slot-0" "$call_log"
}

@test "offload_to_new on slot with no loaded job still transitions to fresh" {
  # Slot 1 is fresh with no job — offload should still work (no-op for job part)
  offload_to_new 1
  slot_status=$(read_pool_json | jq -r '.slots[1].status')
  [ "$slot_status" = "fresh" ]
}

# ---------------------------------------------------------------------------
# prepare_slot_for_new
# ---------------------------------------------------------------------------

@test "prepare_slot_for_new is no-op on fresh slot" {
  run prepare_slot_for_new 1
  [ "$status" -eq 0 ]
  # Slot 1 should still be fresh
  slot_status=$(read_pool_json | jq -r '.slots[1].status')
  [ "$slot_status" = "fresh" ]
}

@test "prepare_slot_for_new offloads idle slot" {
  prepare_slot_for_new 0
  slot_status=$(read_pool_json | jq -r '.slots[0].status')
  [ "$slot_status" = "fresh" ]
}

@test "prepare_slot_for_new fails on busy slot" {
  jq -n '{
    version: 1,
    pool_size: 1,
    queue_seq: 0,
    slots: [{"index":0,"status":"busy","job_id":"aabbccdd","claude_session_id":"uuid-1","last_used_at":"2026-01-01T00:00:00Z"}],
    pins: {}
  }' | update_pool_json
  run prepare_slot_for_new 0
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot prepare"* ]]
}

# ---------------------------------------------------------------------------
# offload_to_resume
# ---------------------------------------------------------------------------

@test "offload_to_resume marks old job offloaded" {
  offload_to_resume 0 "target-uuid" "11223344"
  offloaded=$(jq -r '.offloaded' "$POOL_DIR/jobs/aabbccdd/meta.json")
  [ "$offloaded" = "true" ]
}

@test "offload_to_resume sets slot to idle with target job" {
  mkdir -p "$POOL_DIR/jobs/11223344"
  echo '{"id":"11223344","status":"completed","offloaded":true}' > "$POOL_DIR/jobs/11223344/meta.json"
  offload_to_resume 0 "target-uuid" "11223344"
  slot_status=$(read_pool_json | jq -r '.slots[0].status')
  slot_jid=$(read_pool_json | jq -r '.slots[0].job_id')
  # Slot is idle (not busy) — caller transitions to busy via _locked_claim_and_dispatch
  [ "$slot_status" = "idle" ]
  [ "$slot_jid" = "11223344" ]
}

@test "offload_to_resume stores target uuid on slot" {
  mkdir -p "$POOL_DIR/jobs/11223344"
  echo '{"id":"11223344","status":"completed","offloaded":true}' > "$POOL_DIR/jobs/11223344/meta.json"
  offload_to_resume 0 "target-uuid" "11223344"
  uuid=$(read_pool_json | jq -r '.slots[0].claude_session_id')
  [ "$uuid" = "target-uuid" ]
}

@test "offload_to_resume creates snapshot for old job" {
  offload_to_resume 0 "target-uuid" "11223344"
  [ -f "$POOL_DIR/jobs/aabbccdd/snapshot.log" ]
}

@test "offload_to_resume clears tmux scrollback history for the correct slot" {
  local call_log="$TEST_DIR/tmux_calls.log"
  # shellcheck disable=SC2329
  tmux_cmd() { echo "$*" >> "$call_log"; }
  # shellcheck disable=SC2329
  capture_pane() { echo "mock pane output"; }

  offload_to_resume 0 "target-uuid" "11223344"

  grep -q "clear-history -t pool:slot-0" "$call_log"
}

# ---------------------------------------------------------------------------
# prepare_slot_for_resume
# ---------------------------------------------------------------------------

@test "prepare_slot_for_resume on fresh slot calls offload_to_resume" {
  mkdir -p "$POOL_DIR/jobs/11223344"
  echo '{"id":"11223344","status":"completed","offloaded":true}' > "$POOL_DIR/jobs/11223344/meta.json"
  prepare_slot_for_resume 1 "target-uuid" "11223344"
  # After resume, slot 1 should be idle with target job (caller claims it busy)
  slot_status=$(read_pool_json | jq -r '.slots[1].status')
  slot_jid=$(read_pool_json | jq -r '.slots[1].job_id')
  [ "$slot_status" = "idle" ]
  [ "$slot_jid" = "11223344" ]
}

@test "prepare_slot_for_resume on idle slot calls offload_to_resume" {
  mkdir -p "$POOL_DIR/jobs/11223344"
  echo '{"id":"11223344","status":"completed","offloaded":true}' > "$POOL_DIR/jobs/11223344/meta.json"
  prepare_slot_for_resume 0 "target-uuid" "11223344"
  slot_status=$(read_pool_json | jq -r '.slots[0].status')
  # Slot is idle (not busy) — caller transitions to busy via _locked_claim_and_dispatch
  [ "$slot_status" = "idle" ]
}

@test "prepare_slot_for_resume fails on busy slot" {
  jq -n '{
    version: 1,
    pool_size: 1,
    queue_seq: 0,
    slots: [{"index":0,"status":"busy","job_id":"aabbccdd","claude_session_id":"uuid-1","last_used_at":"2026-01-01T00:00:00Z"}],
    pins: {}
  }' | update_pool_json
  run prepare_slot_for_resume 0 "target-uuid" "11223344"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot prepare for resume"* ]]
}
