#!/usr/bin/env bats
# Live end-to-end tests for claude-pool.
# WARNING: These tests use real Claude sessions and consume API tokens.
#
# Only tests things that REQUIRE real Claude — trust prompt, done hook,
# conversation memory, /resume. Everything else is covered by mock tests.

load '../helpers/live-setup'

setup()    { _live_setup; }
teardown() { _live_teardown; }

# --- Core: pool init with real Claude ---

@test "LIVE: pool init accepts trust prompt and extracts UUIDs" {
  _live_init_pool 2

  # Both slots should be fresh with real UUIDs
  local s0 s1
  s0=$(jq -r '.slots[] | select(.index == 0) | .status' "$POOL_DIR/pool.json")
  s1=$(jq -r '.slots[] | select(.index == 1) | .status' "$POOL_DIR/pool.json")
  [ "$s0" = "fresh" ]
  [ "$s1" = "fresh" ]

  local uuid0
  uuid0=$(jq -r '.slots[] | select(.index == 0) | .claude_session_id' "$POOL_DIR/pool.json")
  [ -n "$uuid0" ] && [ "$uuid0" != "null" ]
  # Real UUIDs contain hyphens
  [[ "$uuid0" == *-* ]]
}

# --- Core: done hook fires on real Claude ---

@test "LIVE: job completes via stop hook (done file appears)" {
  _live_init_pool 1

  local id
  id=$(cmd_start "Say exactly: done-hook-test")

  _live_wait_for_done 0
}

@test "LIVE: watcher marks slot idle after completion" {
  _live_init_pool 1

  local id
  id=$(cmd_start "Say exactly: watcher-test")

  _live_wait_for_slot_status 0 "idle"

  local meta_status
  meta_status=$(jq -r '.status' "$POOL_DIR/jobs/$id/meta.json")
  [ "$meta_status" = "completed" ]
}

# --- Core: conversation context preserved in followup ---

@test "LIVE: followup retains conversation context" {
  _live_init_pool 1

  local id
  id=$(cmd_start "I will say a code. When I ask for it later, reply with ONLY that code and nothing else. The code is: ZQTF-8827-LIVE. Confirm by saying 'stored'.")
  _live_wait_finished "$id"

  local fid
  fid=$(cmd_followup "$id" "What was the code? Reply with ONLY the code, nothing else.")
  _live_wait_finished "$fid"

  local output
  output=$(cmd_result "$fid")
  [[ "$output" == *"ZQTF"* ]] || [[ "$output" == *"8827"* ]]
}

# --- Core: offload + resume restores context ---

@test "LIVE: offloaded session resumes with /resume and retains context" {
  _live_init_pool 1

  # Store a distinctive code
  local id1
  id1=$(cmd_start "I will say a code. When asked, reply ONLY with that code. Code: WKRP-5544-RESUME. Say 'stored'.")
  _live_wait_finished "$id1"

  # Force offload by starting a second job
  local id2
  id2=$(cmd_start "Say exactly: second-job")
  _live_wait_finished "$id2"

  # Verify first is offloaded
  [ "$(get_job_status "$id1")" = "finished(offloaded)" ]
  [ -f "$POOL_DIR/jobs/$id1/snapshot.log" ]

  # Follow up — triggers /resume
  local fid
  fid=$(cmd_followup "$id1" "What was the code? Reply ONLY with the code.")
  _live_wait_finished "$fid"

  local output
  output=$(cmd_result "$fid")
  [[ "$output" == *"WKRP"* ]] || [[ "$output" == *"5544"* ]]
}

# --- Core: queued job dispatches when slot frees ---

@test "LIVE: queued job auto-dispatches after slot frees" {
  _live_init_pool 1

  local id1
  id1=$(cmd_start "Say exactly: first-done")

  local id2
  id2=$(cmd_start "Say exactly: dispatched-from-queue")

  # id2 should be queued
  local s2
  s2=$(jq -r '.status' "$POOL_DIR/jobs/$id2/meta.json")
  [ "$s2" = "queued" ]

  # Wait for both to finish (watcher dispatches id2 after id1 completes)
  _live_wait_finished "$id1"
  _live_wait_finished "$id2"

  local output
  output=$(cmd_result "$id2")
  [ -n "$output" ]
}

# --- Core: --block flag works end-to-end ---

@test "LIVE: start --block returns output inline" {
  _live_init_pool 1

  local output
  output=$(cmd_start --block "Say exactly: block-output")
  [ -n "$output" ]
}
