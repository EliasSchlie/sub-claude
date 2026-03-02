#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031
# Unit tests for cmd_followup guard against processing sessions.
# Covers issue #4: followup must reject processing sessions.

load '../helpers/setup'
load '../helpers/mocks'

setup()    { _common_setup;    }
teardown() { _common_teardown; }

# ---------------------------------------------------------------------------
# Helper: set up a processing job on a busy slot
# ---------------------------------------------------------------------------
_make_processing_job() {
  local job_id="${1:-aabbccdd}" slot="${2:-0}"

  # Pool with one busy slot assigned to this job
  jq -n --arg jid "$job_id" --argjson idx "$slot" '{
    version: 1,
    pool_size: 3,
    queue_seq: 0,
    slots: [
      {index: $idx, status: "busy", job_id: $jid, claude_session_id: "test-uuid", last_used_at: "2026-01-01T00:00:00Z"}
    ],
    pins: {}
  }' | update_pool_json

  # Job meta with processing status
  mkdir -p "$POOL_DIR/jobs/$job_id"
  jq -n --arg jid "$job_id" --argjson slot "$slot" '{
    id: $jid,
    status: "processing",
    slot: $slot,
    claude_session_id: "test-uuid",
    offloaded: false,
    prompt: "original prompt",
    cwd: "/tmp",
    depth: 0
  }' > "$POOL_DIR/jobs/$job_id/meta.json"

  # Slot directory
  mkdir -p "$POOL_DIR/slots/$slot"
}

# ---------------------------------------------------------------------------
# cmd_followup rejects processing sessions
# ---------------------------------------------------------------------------

@test "cmd_followup on processing job exits 1 with still-processing error" {
  _make_processing_job "aabbccdd" 0

  run cmd_followup "aabbccdd" "followup prompt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"still processing"* ]]
}

@test "cmd_followup on processing job mentions the job ID in error" {
  _make_processing_job "aabbccdd" 0

  run cmd_followup "aabbccdd" "followup prompt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"aabbccdd"* ]]
}

# ---------------------------------------------------------------------------
# _locked_claim_and_dispatch clears stale done file
# ---------------------------------------------------------------------------

@test "_locked_claim_and_dispatch clears stale done file from slot" {
  # Set up an idle slot with a leftover done file (from a previous job)
  jq -n '{
    version: 1,
    pool_size: 3,
    queue_seq: 0,
    slots: [
      {index: 0, status: "idle", job_id: "oldjob00", claude_session_id: "old-uuid", last_used_at: "2026-01-01T00:00:00Z"}
    ],
    pins: {}
  }' | update_pool_json

  mkdir -p "$POOL_DIR/slots/0"
  touch "$POOL_DIR/slots/0/done"

  # New job to dispatch
  mkdir -p "$POOL_DIR/jobs/newjob01"
  echo '{"id":"newjob01","status":"queued","slot":null}' > "$POOL_DIR/jobs/newjob01/meta.json"

  # Claim the slot — should also clear the stale done file
  with_pool_lock _locked_claim_and_dispatch 0 "newjob01"

  # Done file must be gone after claim
  [ ! -f "$POOL_DIR/slots/0/done" ]
}

@test "watcher does not mark new job completed due to stale done file after claim" {
  # Simulate the full race scenario:
  # 1. Idle slot with leftover done file
  # 2. _locked_claim_and_dispatch claims the slot for a new job
  # 3. _watcher_phase1 runs — should NOT mark the new job as completed

  jq -n '{
    version: 1,
    pool_size: 1,
    queue_seq: 0,
    slots: [
      {index: 0, status: "idle", job_id: "oldjob00", claude_session_id: "old-uuid", last_used_at: "2026-01-01T00:00:00Z"}
    ],
    pins: {}
  }' | update_pool_json

  mkdir -p "$POOL_DIR/slots/0"
  touch "$POOL_DIR/slots/0/done"

  # New job
  mkdir -p "$POOL_DIR/jobs/newjob01"
  echo '{"id":"newjob01","status":"queued","slot":null}' > "$POOL_DIR/jobs/newjob01/meta.json"

  # Claim (this should clear the done file in the fix)
  with_pool_lock _locked_claim_and_dispatch 0 "newjob01"

  # Simulate watcher phase 1 running after the claim.
  # Pass pane_alive_map with slot 0 alive so watcher doesn't mark it as error.
  _watcher_phase1 "0:1 "

  # Job must still be processing (not completed by watcher)
  local job_status
  job_status=$(jq -r '.status' "$POOL_DIR/jobs/newjob01/meta.json")
  [ "$job_status" = "processing" ]
}
