#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031
# Unit tests for pool state operations: slot allocation and job status.
# Covers allocate_slot and related locked mutation helpers from core.sh and offload.sh.

load '../helpers/setup'
load '../helpers/mocks'

setup()    { _common_setup;    }
teardown() { _common_teardown; }

# ---------------------------------------------------------------------------
# Helper: write a complete pool JSON with given slots array
# ---------------------------------------------------------------------------
_make_pool() {
  local slots="$1"
  jq -n --argjson slots "$slots" '{
    version: 1,
    pool_size: 3,
    queue_seq: 0,
    slots: $slots,
    pins: {}
  }' | update_pool_json
}

# ---------------------------------------------------------------------------
# allocate_slot
# ---------------------------------------------------------------------------

@test "allocate_slot prefers fresh slots over idle" {
  _make_pool '[
    {"index":0,"status":"idle","job_id":"aaaa0000","last_used_at":"2026-01-01T00:00:00Z"},
    {"index":1,"status":"fresh","job_id":null,"last_used_at":null},
    {"index":2,"status":"busy","job_id":"bbbb0000","last_used_at":"2026-01-01T00:00:00Z"}
  ]'
  slot=$(allocate_slot)
  [ "$slot" = "1" ]
}

@test "allocate_slot falls back to LRU idle slot when no fresh" {
  _make_pool '[
    {"index":0,"status":"idle","job_id":"aaaa0000","last_used_at":"2026-01-01T10:00:00Z"},
    {"index":1,"status":"idle","job_id":"bbbb0000","last_used_at":"2026-01-01T09:00:00Z"},
    {"index":2,"status":"busy","job_id":"cccc0000","last_used_at":"2026-01-01T10:00:00Z"}
  ]'
  slot=$(allocate_slot)
  # slot 1 has the older timestamp (LRU)
  [ "$slot" = "1" ]
}

@test "allocate_slot returns 1 (no output) when all slots busy" {
  _make_pool '[
    {"index":0,"status":"busy","job_id":"aaaa0000","last_used_at":"2026-01-01T00:00:00Z"},
    {"index":1,"status":"busy","job_id":"bbbb0000","last_used_at":"2026-01-01T00:00:00Z"}
  ]'
  run allocate_slot
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "allocate_slot skips pinned idle slots" {
  # aaaa0000 is pinned until year 2099 — must not be selected
  jq -n '{
    version: 1,
    pool_size: 2,
    queue_seq: 0,
    slots: [
      {"index":0,"status":"idle","job_id":"aaaa0000","last_used_at":"2026-01-01T09:00:00Z"},
      {"index":1,"status":"idle","job_id":"bbbb0000","last_used_at":"2026-01-01T10:00:00Z"}
    ],
    pins: {"aaaa0000":"2099-01-01T00:00:00Z"}
  }' | update_pool_json
  slot=$(allocate_slot)
  # slot 0 is pinned, so slot 1 is the only eligible one (even though it's newer)
  [ "$slot" = "1" ]
}

@test "allocate_slot returns 1 when only slots are all pinned" {
  jq -n '{
    version: 1,
    pool_size: 1,
    queue_seq: 0,
    slots: [
      {"index":0,"status":"idle","job_id":"aaaa0000","last_used_at":"2026-01-01T00:00:00Z"}
    ],
    pins: {"aaaa0000":"2099-01-01T00:00:00Z"}
  }' | update_pool_json
  run allocate_slot
  [ "$status" -eq 1 ]
}

@test "allocate_slot returns first fresh slot by index order" {
  _make_pool '[
    {"index":0,"status":"busy","job_id":"aaaa0000","last_used_at":"2026-01-01T00:00:00Z"},
    {"index":1,"status":"fresh","job_id":null,"last_used_at":null},
    {"index":2,"status":"fresh","job_id":null,"last_used_at":null}
  ]'
  slot=$(allocate_slot)
  [ "$slot" = "1" ]
}

# ---------------------------------------------------------------------------
# get_job_status
# ---------------------------------------------------------------------------

@test "get_job_status returns queued" {
  mkdir -p "$POOL_DIR/jobs/aabbccdd"
  echo '{"status":"queued"}' > "$POOL_DIR/jobs/aabbccdd/meta.json"
  echo '{"slots":[]}' | update_pool_json
  status=$(get_job_status "aabbccdd")
  [ "$status" = "queued" ]
}

@test "get_job_status returns processing" {
  mkdir -p "$POOL_DIR/jobs/aabbccdd"
  echo '{"status":"processing"}' > "$POOL_DIR/jobs/aabbccdd/meta.json"
  jq -n '{slots:[{index:0,status:"busy",job_id:"aabbccdd"}]}' | update_pool_json
  status=$(get_job_status "aabbccdd")
  [ "$status" = "processing" ]
}

@test "get_job_status returns finished(idle)" {
  mkdir -p "$POOL_DIR/jobs/aabbccdd"
  echo '{"status":"completed","offloaded":false}' > "$POOL_DIR/jobs/aabbccdd/meta.json"
  echo '{"slots":[]}' | update_pool_json
  status=$(get_job_status "aabbccdd")
  [ "$status" = "finished(idle)" ]
}

@test "get_job_status returns finished(offloaded)" {
  mkdir -p "$POOL_DIR/jobs/aabbccdd"
  echo '{"status":"completed","offloaded":true}' > "$POOL_DIR/jobs/aabbccdd/meta.json"
  echo '{"slots":[]}' | update_pool_json
  status=$(get_job_status "aabbccdd")
  [ "$status" = "finished(offloaded)" ]
}

@test "get_job_status returns error for error status" {
  mkdir -p "$POOL_DIR/jobs/aabbccdd"
  echo '{"status":"error"}' > "$POOL_DIR/jobs/aabbccdd/meta.json"
  echo '{"slots":[]}' | update_pool_json
  status=$(get_job_status "aabbccdd")
  [ "$status" = "error" ]
}

@test "get_job_status returns error when processing slot has error status" {
  mkdir -p "$POOL_DIR/jobs/aabbccdd"
  echo '{"status":"processing"}' > "$POOL_DIR/jobs/aabbccdd/meta.json"
  jq -n '{slots:[{index:0,status:"error",job_id:"aabbccdd"}]}' | update_pool_json
  status=$(get_job_status "aabbccdd")
  [ "$status" = "error" ]
}

@test "get_job_status dies for unknown job ID" {
  echo '{"slots":[]}' | update_pool_json
  run get_job_status "deadbeef"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown job ID"* ]]
}

# ---------------------------------------------------------------------------
# get_slot_for_job
# ---------------------------------------------------------------------------

@test "get_slot_for_job finds the correct slot index" {
  jq -n '{slots:[{index:2,status:"busy",job_id:"aabbccdd"}]}' | update_pool_json
  slot=$(get_slot_for_job "aabbccdd")
  [ "$slot" = "2" ]
}

@test "get_slot_for_job returns empty string for unknown job" {
  jq -n '{slots:[{index:0,status:"fresh",job_id:null}]}' | update_pool_json
  slot=$(get_slot_for_job "aabbccdd")
  [ -z "$slot" ]
}

@test "get_slot_for_job returns slot 0 correctly" {
  jq -n '{slots:[{index:0,status:"busy",job_id:"aabbccdd"},{index:1,status:"fresh",job_id:null}]}' | update_pool_json
  slot=$(get_slot_for_job "aabbccdd")
  [ "$slot" = "0" ]
}

# ---------------------------------------------------------------------------
# Locked mutation helpers (slot state)
# ---------------------------------------------------------------------------

@test "_locked_mark_slot_busy sets status busy and assigns job_id" {
  jq -n '{slots:[{index:0,status:"fresh",job_id:null,last_used_at:null}]}' | update_pool_json
  with_pool_lock _locked_mark_slot_busy 0 "aabbccdd"
  status=$(read_pool_json | jq -r '.slots[0].status')
  jid=$(read_pool_json | jq -r '.slots[0].job_id')
  [ "$status" = "busy" ]
  [ "$jid" = "aabbccdd" ]
}

@test "_locked_mark_slot_busy sets last_used_at timestamp" {
  jq -n '{slots:[{index:0,status:"fresh",job_id:null,last_used_at:null}]}' | update_pool_json
  with_pool_lock _locked_mark_slot_busy 0 "aabbccdd"
  ts=$(read_pool_json | jq -r '.slots[0].last_used_at')
  [ -n "$ts" ]
  [ "$ts" != "null" ]
}

@test "_locked_update_slot_fresh resets slot to fresh state" {
  jq -n '{slots:[{index:0,status:"idle",job_id:"aabbccdd",last_used_at:"2026-01-01",claude_session_id:"old-uuid"}]}' | update_pool_json
  with_pool_lock _locked_update_slot_fresh 0 "new-uuid"
  status=$(read_pool_json | jq -r '.slots[0].status')
  jid=$(read_pool_json | jq -r '.slots[0].job_id')
  uuid=$(read_pool_json | jq -r '.slots[0].claude_session_id')
  [ "$status" = "fresh" ]
  [ "$jid" = "null" ]
  [ "$uuid" = "new-uuid" ]
}

@test "_locked_update_slot_idle sets status idle and keeps job_id" {
  jq -n '{slots:[{index:0,status:"busy",job_id:"aabbccdd",last_used_at:null}]}' | update_pool_json
  with_pool_lock _locked_update_slot_idle 0 "aabbccdd"
  status=$(read_pool_json | jq -r '.slots[0].status')
  jid=$(read_pool_json | jq -r '.slots[0].job_id')
  [ "$status" = "idle" ]
  [ "$jid" = "aabbccdd" ]
}

@test "_locked_update_slot_idle_resume updates slot for resume" {
  jq -n '{slots:[{index:0,status:"fresh",job_id:null,claude_session_id:"old-uuid",last_used_at:null}]}' | update_pool_json
  with_pool_lock _locked_update_slot_idle_resume 0 "aabbccdd" "resume-uuid"
  status=$(read_pool_json | jq -r '.slots[0].status')
  jid=$(read_pool_json | jq -r '.slots[0].job_id')
  uuid=$(read_pool_json | jq -r '.slots[0].claude_session_id')
  # Slot is idle (not busy) — caller transitions to busy via _locked_claim_and_dispatch
  [ "$status" = "idle" ]
  [ "$jid" = "aabbccdd" ]
  [ "$uuid" = "resume-uuid" ]
}

# ---------------------------------------------------------------------------
# _locked_claim_and_dispatch
# ---------------------------------------------------------------------------

@test "_locked_claim_and_dispatch claims fresh slot and marks job processing" {
  jq -n '{slots:[{index:0,status:"fresh",job_id:null,claude_session_id:"u1",last_used_at:null}],pins:{}}' | update_pool_json
  mkdir -p "$POOL_DIR/jobs/aabbccdd"
  echo '{"id":"aabbccdd","status":"queued","slot":null}' > "$POOL_DIR/jobs/aabbccdd/meta.json"
  with_pool_lock _locked_claim_and_dispatch 0 "aabbccdd"
  status=$(read_pool_json | jq -r '.slots[0].status')
  jid=$(read_pool_json | jq -r '.slots[0].job_id')
  job_status=$(jq -r '.status' "$POOL_DIR/jobs/aabbccdd/meta.json")
  job_slot=$(jq -r '.slot' "$POOL_DIR/jobs/aabbccdd/meta.json")
  [ "$status" = "busy" ]
  [ "$jid" = "aabbccdd" ]
  [ "$job_status" = "processing" ]
  [ "$job_slot" = "0" ]
}

@test "_locked_claim_and_dispatch fails on busy slot" {
  jq -n '{slots:[{index:0,status:"busy",job_id:"other",claude_session_id:"u1",last_used_at:null}],pins:{}}' | update_pool_json
  mkdir -p "$POOL_DIR/jobs/aabbccdd"
  echo '{"id":"aabbccdd","status":"queued","slot":null}' > "$POOL_DIR/jobs/aabbccdd/meta.json"
  run with_pool_lock _locked_claim_and_dispatch 0 "aabbccdd"
  [ "$status" -eq 1 ]
}

@test "_locked_claim_and_dispatch claims idle slot" {
  jq -n '{slots:[{index:0,status:"idle",job_id:"old",claude_session_id:"u1",last_used_at:null}],pins:{}}' | update_pool_json
  mkdir -p "$POOL_DIR/jobs/newjob01"
  echo '{"id":"newjob01","status":"queued","slot":null}' > "$POOL_DIR/jobs/newjob01/meta.json"
  with_pool_lock _locked_claim_and_dispatch 0 "newjob01"
  status=$(read_pool_json | jq -r '.slots[0].status')
  [ "$status" = "busy" ]
}

# ---------------------------------------------------------------------------
# Pin helpers
# ---------------------------------------------------------------------------

@test "_locked_set_pin adds pin entry to pool.json" {
  echo '{"version":1,"slots":[],"pins":{}}' | update_pool_json
  with_pool_lock _locked_set_pin "aabbccdd" "2099-01-01T00:00:00Z"
  expiry=$(read_pool_json | jq -r '.pins.aabbccdd')
  [ "$expiry" = "2099-01-01T00:00:00Z" ]
}

@test "_locked_remove_pin deletes the pin entry" {
  jq -n '{"version":1,"slots":[],"pins":{"aabbccdd":"2099-01-01T00:00:00Z"}}' | update_pool_json
  with_pool_lock _locked_remove_pin "aabbccdd"
  expiry=$(read_pool_json | jq -r '.pins.aabbccdd // "gone"')
  [ "$expiry" = "gone" ]
}
